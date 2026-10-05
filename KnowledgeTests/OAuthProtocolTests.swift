import Foundation
import Testing
@testable import Knowledge

struct OAuthProtocolTests {
    private let attempt = OAuthAttempt(state: "expected-state", nonce: "nonce", verifier: "verifier",
                                       bridgeID: "opaque-bridge", existingClientID: nil)

    @Test func pkceMatchesRFC7636() {
        #expect(OAuthProtocol.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func generatedSecretsAreIndependentAndURLSafe() throws {
        let generated = try OAuthAttempt.make(existingClientID: nil)
        let values = [generated.state, generated.nonce, generated.verifier, generated.bridgeID]
        #expect(Set(values).count == 4)
        #expect(values.allSatisfy { $0.count == 43 && $0.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil })
    }

    @Test func initialAuthorizationUsesDynamicClientAndExactLoopback() throws {
        let request = OAuthBrowserRequest(authorizationEndpoint: URL(string: "https://auth.openai.com/api/accounts/authorize")!,
                                          hostID: "urn:uuid:example", account: nil, requestConsent: false)
        let redirect = OAuthProtocol.redirectURI(port: 54321)
        let url = try OAuthProtocol.authorizationURL(request: request, attempt: attempt, redirectURI: redirect)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(query["client_id"] == "dynamic_agent_client")
        #expect(query["agent_name_hint"] == "Knowledge")
        #expect(query["redirect_uri"] == "http://127.0.0.1:54321/auth/callback")
        #expect(query["nonce"] == attempt.nonce)
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["resource"] == ChatGPTConfiguration.resource)
        #expect(query["scope"] == ChatGPTConfiguration.scopes)
        #expect(query["prompt"] == nil)
    }

    @Test func returningAuthorizationUsesSavedClientAndConsentOnlyWhenRequested() throws {
        let account = StoredChatGPTAccount(clientID: "oaiapp_saved", identity: ChatGPTIdentity(issuer: "https://auth.openai.com", subject: "subject", name: nil, email: "person@example.com", picture: nil), label: "Connection 1", credentials: ChatGPTCredentials(idToken: "old-id-token", accessToken: nil, refreshToken: nil, expiresAt: nil, scopes: [], earliestRefreshAt: nil))
        let request = OAuthBrowserRequest(authorizationEndpoint: URL(string: "https://auth.openai.com/api/accounts/authorize")!, hostID: "urn:uuid:example", account: account, requestConsent: true)
        let existing = OAuthAttempt(state: "state", nonce: "nonce", verifier: "verifier", bridgeID: "bridge", existingClientID: account.clientID)
        let url = try OAuthProtocol.authorizationURL(request: request, attempt: existing, redirectURI: OAuthProtocol.redirectURI(port: 12345))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(query["client_id"] == account.clientID)
        #expect(query["agent_name_hint"] == nil)
        #expect(query["id_token_hint"] == "old-id-token")
        #expect(query["login_hint"] == "person@example.com")
        #expect(query["prompt"] == "consent")
    }

    @Test func newRegistrationRequiresIssuedClientID() throws {
        #expect(try OAuthProtocol.callback(from: "/auth/callback?state=expected-state&code=code&client_id=oaiapp_new", attempt: attempt)
                == .authorization(code: "code", clientID: "oaiapp_new"))
        #expect(throws: AuthenticationError.incompleteRegistration) {
            try OAuthProtocol.callback(from: "/auth/callback?state=expected-state&code=code", attempt: attempt)
        }
        #expect(throws: AuthenticationError.incompleteRegistration) {
            try OAuthProtocol.callback(from: "/auth/callback?state=expected-state&code=code&client_id=dynamic_agent_client", attempt: attempt)
        }
    }

    @Test func incompleteRegistrationRetryReusesIssuedClientWithoutAccountHints() throws {
        let request = OAuthBrowserRequest(authorizationEndpoint: URL(string: "https://auth.openai.com/api/accounts/authorize")!,
                                          hostID: "urn:uuid:example", account: nil, requestConsent: false, registrationClientID: "oaiapp_retry")
        let retry = OAuthAttempt(state: "state", nonce: "nonce", verifier: "verifier", bridgeID: "bridge", existingClientID: request.registrationClientID)
        let url = try OAuthProtocol.authorizationURL(request: request, attempt: retry, redirectURI: OAuthProtocol.redirectURI(port: 12345))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(query["client_id"] == "oaiapp_retry")
        #expect(query["agent_name_hint"] == nil)
        #expect(query["id_token_hint"] == nil)
        #expect(query["login_hint"] == nil)
    }

    @Test(arguments: [
        "/auth/callback?state=wrong&code=x&client_id=oaiapp_new",
        "/auth/callback?state=expected-state&state=expected-state&code=x&client_id=oaiapp_new",
        "/auth/callback?state=expected-state&%73tate=expected-state&code=x&client_id=oaiapp_new",
        "/auth/callback?state=expected-state&code=x&error=access_denied&client_id=oaiapp_new",
        "/auth/callback?state=expected-state&code=&client_id=oaiapp_new",
        "/callback?state=expected-state&code=x&client_id=oaiapp_new",
        "/auth/callback?state=expected-state&code=x&client_id=oaiapp_new#fragment"
    ]) func ambiguousCallbacksAreRejected(_ target: String) {
        #expect(throws: AuthenticationError.invalidCallback) { try OAuthProtocol.callback(from: target, attempt: attempt) }
    }

    @Test func returningCallbackCannotReplaceClientID() throws {
        let existing = OAuthAttempt(state: "state", nonce: "nonce", verifier: "verifier", bridgeID: "bridge", existingClientID: "oaiapp_saved")
        #expect(try OAuthProtocol.callback(from: "/auth/callback?state=state&code=x", attempt: existing)
                == .authorization(code: "x", clientID: "oaiapp_saved"))
        #expect(throws: AuthenticationError.invalidCallback) {
            try OAuthProtocol.callback(from: "/auth/callback?state=state&code=x&client_id=oaiapp_other", attempt: existing)
        }
    }

    @Test func denialDoesNotRequireRegistration() throws {
        #expect(try OAuthProtocol.callback(from: "/auth/callback?state=expected-state&error=access_denied&error_description=private", attempt: attempt)
                == .denied("access_denied"))
    }

    @Test func bridgeContainsOnlyOpaqueAttemptAndMustMatchExactly() throws {
        let bridge = OAuthProtocol.bridgeURL(attemptID: attempt.bridgeID)
        try OAuthProtocol.validateBridge(bridge, attemptID: attempt.bridgeID)
        #expect(!bridge.absoluteString.contains("code="))
        #expect(throws: AuthenticationError.invalidCallback) { try OAuthProtocol.validateBridge(bridge, attemptID: "other") }
        #expect(throws: AuthenticationError.invalidCallback) {
            try OAuthProtocol.validateBridge(URL(string: bridge.absoluteString + "&attempt=opaque-bridge")!, attemptID: attempt.bridgeID)
        }
        #expect(throws: AuthenticationError.invalidCallback) {
            try OAuthProtocol.validateBridge(URL(string: "dev.kiwiapps.knowledge.auth://complete/extra?attempt=opaque-bridge")!, attemptID: attempt.bridgeID)
        }
    }

    @Test func fragmentedHeadersWaitUntilComplete() throws {
        var buffer = OAuthHeaderBuffer()
        #expect(try buffer.append(Data("GET /auth/callback?state=expected-state HTTP/1.1\r\nHost: 127.0.0.1:12345\r\n".utf8)) == nil)
        let completed = try buffer.append(Data("\r\n".utf8))
        let headers = try #require(completed)
        #expect(try OAuthProtocol.requestTarget(headers: headers, port: 12345) == "/auth/callback?state=expected-state")
    }

    @Test(arguments: [
        "POST /auth/callback HTTP/1.1\r\nHost: 127.0.0.1:12345\r\n\r\n",
        "GET /auth/callback HTTP/1.1\r\nHost: localhost:12345\r\n\r\n",
        "GET /auth/callback HTTP/1.1\r\nHost: 127.0.0.1:12345\r\nHOST: 127.0.0.1:12345\r\n\r\n",
        "GET /auth/callback HTTP/1.1\r\nHost: 127.0.0.1:12345\r\nContent-Length: 1\r\n\r\n",
        "GET http://127.0.0.1:12345/auth/callback HTTP/1.1\r\nHost: 127.0.0.1:12345\r\n\r\n"
    ]) func invalidHTTPRequestsAreRejected(_ text: String) {
        #expect(throws: AuthenticationError.invalidCallback) {
            try OAuthProtocol.requestTarget(headers: Data(text.utf8), port: 12345)
        }
    }

    @Test func headerBufferRejectsOversizedHeadersAndBodies() {
        var oversized = OAuthHeaderBuffer()
        #expect(throws: AuthenticationError.invalidCallback) { try oversized.append(Data(repeating: 65, count: 16_385)) }
        var body = OAuthHeaderBuffer()
        #expect(throws: AuthenticationError.invalidCallback) { try body.append(Data("GET / HTTP/1.1\r\n\r\nbody".utf8)) }
    }
}
