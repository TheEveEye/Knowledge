import Foundation
import Security
import Testing
@testable import Knowledge

@MainActor @Suite("ChatGPT OAuth transport and identity")
struct APIClientTests {
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var discovery: [String: Any] {
        ["issuer": "https://auth.openai.com",
         "authorization_endpoint": "https://auth.openai.com/api/accounts/authorize",
         "token_endpoint": "https://auth.openai.com/api/accounts/oauth/token",
         "jwks_uri": "https://auth.openai.com/.well-known/jwks.json",
         "revocation_endpoint": "https://auth.openai.com/api/accounts/oauth/revoke"]
    }
    private var grant: [String: Any] {
        ["id_token": "synthetic-id", "access_token": "synthetic-access", "refresh_token": "synthetic-refresh",
         "token_type": "Bearer", "expires_in": 3600, "scope": ChatGPTConfiguration.scopes]
    }
    private var authorization: OAuthAuthorization {
        .init(code: "synthetic-code+&= ü", clientID: "oaiapp_fixture", verifier: "synthetic-verifier+/=",
              nonce: "fixture-nonce", redirectURI: URL(string: "http://127.0.0.1:54321/auth/callback")!)
    }
    private func account() -> StoredChatGPTAccount {
        .init(clientID: "oaiapp_fixture", identity: .init(issuer: "https://auth.openai.com", subject: "fixture-subject",
             name: nil, email: nil, picture: nil), label: "Connection 1",
              credentials: .init(idToken: "synthetic-id", accessToken: "synthetic-access", refreshToken: "synthetic-refresh",
              expiresAt: clock, scopes: ChatGPTConfiguration.scopes.split(separator: " ").map(String.init), earliestRefreshAt: nil))
    }
    private func client(_ values: [HTTPFixture], at date: Date? = nil) throws -> (ChatGPTAPIClient, FixtureHTTPTransport) {
        let transport = FixtureHTTPTransport(responses: [try .json(discovery)] + values)
        let now = date ?? clock
        return (ChatGPTAPIClient(transport: transport, now: { now }, sleep: { _ in }), transport)
    }

    @Test func trustedDiscoveryIsCached() async throws {
        let (api, transport) = try client([])
        let first = try await api.authorizationEndpoint()
        let second = try await api.authorizationEndpoint()
        #expect(first == URL(string: discovery["authorization_endpoint"] as! String))
        #expect(first == second)
        #expect(transport.requests.count == 1)
    }

    @Test(arguments: ["issuer", "authorization_endpoint", "token_endpoint", "jwks_uri", "revocation_endpoint"])
    func untrustedDiscoveryCannotRedirectCredentials(_ field: String) async throws {
        var value = discovery
        value[field] = "https://untrusted.invalid/endpoint"
        let transport = FixtureHTTPTransport(responses: [try .json(value)])
        let api = ChatGPTAPIClient(transport: transport)
        await #expect(throws: AuthenticationError.invalidResponse) { try await api.authorizationEndpoint() }
        #expect(transport.requests.count == 1)
    }

    @Test func exchangeFormEncodesValuesAndUsesIssuedRegistration() async throws {
        let (api, transport) = try client([try .json(grant)])
        let result = try await api.exchange(authorization)
        let request = try #require(transport.requests.last)
        let form = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        let encodedCode = form.contains("code=synthetic-code%2B%26%3D+%C3%BC")
        let encodedVerifier = form.contains("code_verifier=synthetic-verifier%2B%2F%3D")
        let issuedID = form.contains("client_id=oaiapp_fixture") && !form.contains("dynamic_agent_client")
        let exactRedirect = form.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A54321%2Fauth%2Fcallback")
        #expect(encodedCode && encodedVerifier && issuedID && exactRedirect)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(result.credentials.planEnabled)
        #expect(result.credentials.expiresAt == clock.addingTimeInterval(3600))
    }

    @Test func identityOnlyGrantDoesNotRequireBearerCredentials() async throws {
        let (api, _) = try client([try .json(["id_token": "synthetic-id", "scope": "openid profile email"])])
        let credentials = try await api.exchange(authorization).credentials
        let hasBearer = credentials.accessToken != nil || credentials.refreshToken != nil
        #expect(!hasBearer)
        #expect(!credentials.planEnabled)
    }

    @Test(arguments: ["access_token", "refresh_token", "token_type", "expires_in", "scope"])
    func incompleteBearerGrantIsRejected(_ field: String) async throws {
        var value = grant
        value.removeValue(forKey: field)
        let (api, _) = try client([try .json(value)])
        await #expect(throws: AuthenticationError.invalidResponse) { try await api.exchange(authorization) }
    }

    @Test func refreshRetainsScopesButLeavesOmittedIdentityForStoreToRetain() async throws {
        var value = grant
        value.removeValue(forKey: "scope")
        value.removeValue(forKey: "id_token")
        let (api, transport) = try client([try .json(value)])
        let saved = account()
        let renewed = try await api.refresh(saved).credentials
        let hasIdentity = renewed.idToken != nil
        #expect(!hasIdentity)
        #expect(Set(renewed.scopes) == Set(saved.credentials!.scopes))
        #expect(renewed.planEnabled)
        let form = String(data: transport.requests.last?.httpBody ?? Data(), encoding: .utf8) ?? ""
        let preservesGrant = !form.contains("scope=") && form.contains("grant_type=refresh_token")
        #expect(preservesGrant)
    }

    @Test func revokeUsesNewestCheckpointAndAcceptsEmptySuccess() async throws {
        let (api, transport) = try client([HTTPFixture(data: Data())])
        var saved = account()
        saved.pendingRefresh = saved.credentials
        saved.pendingRefresh?.refreshToken = "synthetic-replacement"
        try await api.revoke(saved)
        let form = String(data: transport.requests.last?.httpBody ?? Data(), encoding: .utf8) ?? ""
        let usesLatest = form.contains("token=synthetic-replacement") && form.contains("token_type_hint=refresh_token")
        #expect(usesLatest)
        #expect(transport.requests.last?.url?.path == "/api/accounts/oauth/revoke")
    }

    @Test func revocationRetriesOnlyTemporaryFailuresWithBoundedBackoff() async throws {
        let transport = FixtureHTTPTransport(responses: [try .json(discovery),
            HTTPFixture(data: Data(), status: 503), HTTPFixture(data: Data(), status: 500), HTTPFixture(data: Data())])
        var delays: [Duration] = []
        let api = ChatGPTAPIClient(transport: transport, sleep: { delays.append($0) })
        try await api.revoke(account())
        #expect(delays == [.seconds(1), .seconds(2)])
        #expect(transport.requests.count == 4)
        let (permanent, permanentTransport) = try client([HTTPFixture(data: Data(), status: 400)])
        await #expect(throws: AuthenticationError.http(400, nil)) { try await permanent.revoke(account()) }
        #expect(permanentTransport.requests.count == 2)
    }

    @Test func machineErrorPreservesStatusWithoutServerDescriptions() async throws {
        let (api, _) = try client([try .json(["error": "refresh_token_reused", "error_description": "private server details"], status: 400)])
        await #expect(throws: AuthenticationError.http(400, "refresh_token_reused")) { try await api.refresh(account()) }
        #expect(AuthenticationError.http(400, "refresh_token_reused").isTerminalRefreshError)
        #expect(!AuthenticationError.http(503, nil).isTerminalRefreshError)
    }

    @Test func arbitraryErrorBodyAndNetworkDetailsAreSanitized() async throws {
        let (api, transport) = try client([try .json(["detail": "private server details"], status: 503)])
        await #expect(throws: AuthenticationError.http(503, nil)) { try await api.exchange(authorization) }
        transport.error = URLError(.notConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: "private transport details"])
        await #expect(throws: AuthenticationError.http(0, nil)) { try await api.exchange(authorization) }
    }

    @Test func signedIdentityUsesVerifiedClaimsAndAudienceArray() async throws {
        let signing = try IdentitySigningFixture()
        var claims = identityClaims()
        claims["aud"] = ["oaiapp_fixture", "another-client"]
        claims["azp"] = "oaiapp_fixture"
        let (api, _) = try client([try .json(signing.jwks())])
        let token = try signing.sign(claims)
        let identity = try await api.verifyIdentity(idToken: token, clientID: "oaiapp_fixture", nonce: "fixture-nonce")
        #expect(identity.subject == "fixture-subject")
        #expect(identity.email == "fixture@invalid.test")
    }

    @Test(arguments: ["issuer", "audience", "expiry", "nonce", "subject", "authorized-party", "multi-audience", "not-before"])
    func invalidSignedClaimsAreRejected(_ kind: String) async throws {
        let signing = try IdentitySigningFixture()
        var claims = identityClaims()
        switch kind {
        case "issuer": claims["iss"] = "https://untrusted.invalid"
        case "audience": claims["aud"] = "another-client"
        case "expiry": claims["exp"] = clock.timeIntervalSince1970 - 60
        case "nonce": claims["nonce"] = "another-nonce"
        case "subject": claims["sub"] = ""
        case "authorized-party": claims["azp"] = "another-client"
        case "multi-audience": claims["aud"] = ["oaiapp_fixture", "another-client"]
        default: claims["nbf"] = clock.timeIntervalSince1970 + 60
        }
        let token = try signing.sign(claims)
        let (api, _) = try client([try .json(signing.jwks())])
        await #expect(throws: AuthenticationError.invalidIdentity) {
            try await api.verifyIdentity(idToken: token, clientID: "oaiapp_fixture", nonce: "fixture-nonce")
        }
    }

    @Test func alteredSignatureCannotSupplyIdentity() async throws {
        let signing = try IdentitySigningFixture()
        var pieces = try signing.sign(identityClaims()).split(separator: ".").map(String.init)
        pieces[2] = (pieces[2].first == "A" ? "B" : "A") + pieces[2].dropFirst()
        let token = pieces.joined(separator: ".")
        let (api, _) = try client([try .json(signing.jwks())])
        await #expect(throws: AuthenticationError.invalidIdentity) {
            try await api.verifyIdentity(idToken: token, clientID: "oaiapp_fixture", nonce: "fixture-nonce")
        }
    }

    @Test func unknownKeyRefreshesCatalogWithoutDefaultKeyFallback() async throws {
        let signing = try IdentitySigningFixture()
        let (api, transport) = try client([try .json(signing.jwks()), try .json(signing.jwks(kid: "rotated-key"))])
        _ = try await api.verifyIdentity(idToken: signing.sign(identityClaims()), clientID: "oaiapp_fixture", nonce: "fixture-nonce")
        _ = try await api.verifyIdentity(idToken: signing.sign(identityClaims(), kid: "rotated-key"), clientID: "oaiapp_fixture", nonce: "fixture-nonce")
        #expect(transport.requests.count == 3)
        let (other, _) = try client([try .json(signing.jwks())])
        let token = try signing.sign(identityClaims(), kid: "unknown-key")
        await #expect(throws: AuthenticationError.invalidIdentity) {
            try await other.verifyIdentity(idToken: token, clientID: "oaiapp_fixture", nonce: "fixture-nonce")
        }
    }

    @Test func unsupportedSigningAlgorithmIsRejectedBeforeNetworking() async throws {
        let signing = try IdentitySigningFixture()
        let token = try signing.sign(identityClaims(), algorithm: "HS256")
        let transport = FixtureHTTPTransport(responses: [])
        let api = ChatGPTAPIClient(transport: transport)
        await #expect(throws: AuthenticationError.invalidIdentity) {
            try await api.verifyIdentity(idToken: token, clientID: "oaiapp_fixture", nonce: "fixture-nonce")
        }
        #expect(transport.requests.isEmpty)
    }

    @Test(arguments: ["critical", "unencoded-payload"])
    func unsupportedCriticalHeadersAreRejectedBeforeNetworking(_ kind: String) async throws {
        let signing = try IdentitySigningFixture()
        let token = try signing.sign(identityClaims(), critical: kind == "critical" ? ["unsupported"] : nil,
                                     base64Encoded: kind == "unencoded-payload" ? false : nil)
        let transport = FixtureHTTPTransport(responses: [])
        let api = ChatGPTAPIClient(transport: transport)
        await #expect(throws: AuthenticationError.invalidIdentity) {
            try await api.verifyIdentity(idToken: token, clientID: "oaiapp_fixture", nonce: "fixture-nonce")
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func checkpointIdentityUsesReceiptTimeAndStillVerifiesSignature() async throws {
        let signing = try IdentitySigningFixture()
        let token = try signing.sign(identityClaims())
        let (api, _) = try client([try .json(signing.jwks())], at: clock.addingTimeInterval(7200))
        await #expect(throws: AuthenticationError.invalidIdentity) {
            try await api.verifyIdentity(idToken: token, clientID: "oaiapp_fixture", nonce: "fixture-nonce")
        }
        let identity = try await api.verifyRefreshedIdentity(idToken: token, clientID: "oaiapp_fixture", receivedAt: clock)
        #expect(identity.subject == "fixture-subject")
        var pieces = token.split(separator: ".").map(String.init)
        pieces[2] = (pieces[2].first == "A" ? "B" : "A") + pieces[2].dropFirst()
        let altered = pieces.joined(separator: ".")
        await #expect(throws: AuthenticationError.invalidIdentity) {
            try await api.verifyRefreshedIdentity(idToken: altered, clientID: "oaiapp_fixture", receivedAt: clock)
        }
    }

    @Test func checkpointCannotSupplyFutureReceiptTime() async throws {
        let signing = try IdentitySigningFixture()
        let token = try signing.sign(identityClaims())
        let (api, transport) = try client([])
        await #expect(throws: AuthenticationError.invalidIdentity) {
            try await api.verifyRefreshedIdentity(idToken: token, clientID: "oaiapp_fixture", receivedAt: clock.addingTimeInterval(1))
        }
        #expect(transport.requests.isEmpty)
    }

    private func identityClaims() -> [String: Any] {
        ["iss": "https://auth.openai.com", "aud": "oaiapp_fixture", "sub": "fixture-subject",
         "exp": clock.timeIntervalSince1970 + 3600, "iat": clock.timeIntervalSince1970,
         "nonce": "fixture-nonce", "email": "fixture@invalid.test"]
    }
}

@MainActor private final class FixtureHTTPTransport: ChatGPTHTTPTransport {
    var responses: [HTTPFixture]
    var requests: [URLRequest] = []
    var error: (any Error)?
    init(responses: [HTTPFixture]) { self.responses = responses }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let error { throw error }
        guard !responses.isEmpty else { throw AuthenticationError.invalidResponse }
        let next = responses.removeFirst()
        return (next.data, HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: "HTTP/1.1", headerFields: next.headers)!)
    }
}

private struct HTTPFixture {
    let data: Data
    var status = 200
    var headers: [String: String] = [:]
    static func json(_ object: [String: Any], status: Int = 200) throws -> Self {
        .init(data: try JSONSerialization.data(withJSONObject: object), status: status)
    }
}

// Generate throwaway RSA fixtures rather than copying or checking in any private credential.
@MainActor private final class IdentitySigningFixture {
    private let key: SecKey
    private let modulus: Data
    private let exponent: Data
    init() throws {
        let generatedKey = try #require(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil))
        key = generatedKey
        let publicKey = try #require(SecKeyCopyPublicKey(generatedKey))
        let representation = try #require(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        var cursor = 0
        func length() throws -> Int {
            guard cursor < representation.count else { throw AuthenticationError.invalidResponse }
            let first = Int(representation[cursor]); cursor += 1
            if first < 128 { return first }
            let bytes = first & 127
            guard bytes > 0, bytes <= 4, cursor + bytes <= representation.count else { throw AuthenticationError.invalidResponse }
            var value = 0
            for _ in 0..<bytes { value = value * 256 + Int(representation[cursor]); cursor += 1 }
            return value
        }
        guard representation[cursor] == 0x30 else { throw AuthenticationError.invalidResponse }
        cursor += 1
        _ = try length()
        func integer() throws -> Data {
            guard cursor < representation.count, representation[cursor] == 0x02 else { throw AuthenticationError.invalidResponse }
            cursor += 1
            let count = try length()
            guard cursor + count <= representation.count else { throw AuthenticationError.invalidResponse }
            let value = representation.subdata(in: cursor..<cursor + count)
            cursor += count
            return value.first == 0 ? Data(value.dropFirst()) : value
        }
        modulus = try integer()
        exponent = try integer()
    }
    func jwks(kid: String = "fixture-key") -> [String: Any] {
        ["keys": [["kty": "RSA", "alg": "RS256", "use": "sig", "kid": kid,
                   "n": base64URL(modulus), "e": base64URL(exponent)]]]
    }
    func sign(_ claims: [String: Any], kid: String = "fixture-key", algorithm: String = "RS256",
              critical: [String]? = nil, base64Encoded: Bool? = nil) throws -> String {
        var fields: [String: Any] = ["alg": algorithm, "kid": kid, "typ": "JWT"]
        if let critical { fields["crit"] = critical }
        if let base64Encoded { fields["b64"] = base64Encoded }
        let header = try JSONSerialization.data(withJSONObject: fields, options: .sortedKeys)
        let payload = try JSONSerialization.data(withJSONObject: claims, options: .sortedKeys)
        let value = base64URL(header) + "." + base64URL(payload)
        let signature = try #require(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(value.utf8) as CFData, nil)) as Data
        return value + "." + base64URL(signature)
    }
    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
