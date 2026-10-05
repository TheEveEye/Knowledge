import Foundation

nonisolated enum ChatGPTConfiguration {
    static let issuer = URL(string: "https://auth.openai.com")!
    static let resource = "https://api.openai.com/v1"
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static let callbackScheme = "dev.kiwiapps.knowledge.auth"
    static let planScope = "chatgpt.tokens.use.direct"
}

nonisolated enum AuthenticationError: Error, LocalizedError, Equatable {
    case canceled, timedOut, backgrounded, invalidCallback, incompleteRegistration
    case invalidIdentity, invalidResponse, browserUnavailable, sessionExpired, storage(Int32)
    case oauth(String), http(Int, String?)

    var errorDescription: String? {
        switch self {
        case .canceled: "Sign-in was canceled."
        case .timedOut: "Sign-in timed out. Please try again."
        case .backgrounded: "Sign-in was interrupted. Keep Knowledge open and try again."
        case .invalidCallback: "The sign-in response could not be verified. Please try again."
        case .incompleteRegistration: "ChatGPT did not finish registering this connection. Please try again."
        case .invalidIdentity: "The ChatGPT account could not be verified. Please sign in again."
        case .invalidResponse: "ChatGPT returned an incomplete response. Please try again."
        case .browserUnavailable: "The sign-in browser could not open. Please try again."
        case .sessionExpired: "Your ChatGPT connection has expired. Please sign in again."
        case .storage: "Your connection could not be saved securely. Please try again."
        case .oauth("access_denied"): "Sign-in was not authorized. You can try again."
        case .oauth("invalid_client"): "This ChatGPT connection is no longer available."
        case .oauth: "ChatGPT could not complete sign-in. Please try again."
        case .http: "ChatGPT is temporarily unavailable. Please try again."
        }
    }

    var isTerminalRefreshError: Bool {
        let terminal = ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"]
        switch self {
        case .sessionExpired: return true
        case .oauth(let code), .http(_, let code?): return terminal.contains(code)
        default: return false
        }
    }
}

nonisolated struct ChatGPTIdentity: Codable, Sendable, Equatable {
    let issuer: String
    let subject: String
    let name: String?
    let email: String?
    let picture: String?

    var displayName: String { name ?? email ?? "ChatGPT account" }
}

nonisolated struct ChatGPTCredentials: Codable, Sendable, Equatable {
    var idToken: String?
    var accessToken: String?
    var refreshToken: String?
    var expiresAt: Date?
    var scopes: [String]
    var earliestRefreshAt: String?
    var receivedAt: Date? = nil

    var planEnabled: Bool { accessToken != nil && scopes.contains(ChatGPTConfiguration.planScope) }
}

nonisolated struct StoredChatGPTAccount: Codable, Sendable, Equatable, Identifiable {
    let clientID: String
    let identity: ChatGPTIdentity
    var label: String
    var credentials: ChatGPTCredentials?
    // Persist rotated tokens before network-dependent identity verification can fail.
    var pendingRefresh: ChatGPTCredentials? = nil
    var id: String { clientID }
}

nonisolated struct OAuthBrowserRequest: Sendable {
    let authorizationEndpoint: URL
    let hostID: String
    let account: StoredChatGPTAccount?
    let requestConsent: Bool
    var registrationClientID: String? = nil
}

nonisolated struct OAuthAuthorization: Sendable {
    let code: String
    let clientID: String
    let verifier: String
    let nonce: String
    let redirectURI: URL
}

nonisolated struct OAuthTokenResponse: Sendable {
    let credentials: ChatGPTCredentials
}

@MainActor protocol ChatGPTCredentialStorage {
    func hostID() throws -> String
    func loadAccounts() throws -> [StoredChatGPTAccount]
    func saveAccount(_ account: StoredChatGPTAccount) throws
    func activeAccountID() throws -> String?
    func setActiveAccountID(_ clientID: String?) throws
    func pendingRegistrationClientID() throws -> String?
    func setPendingRegistrationClientID(_ clientID: String?) throws
}

@MainActor protocol ChatGPTAuthenticating {
    func authorizationEndpoint() async throws -> URL
    func exchange(_ authorization: OAuthAuthorization) async throws -> OAuthTokenResponse
    func refresh(_ account: StoredChatGPTAccount) async throws -> OAuthTokenResponse
    func verifyIdentity(idToken: String, clientID: String, nonce: String?) async throws -> ChatGPTIdentity
    func revoke(_ account: StoredChatGPTAccount) async throws
    func verifyRefreshedIdentity(idToken: String, clientID: String, receivedAt: Date?) async throws -> ChatGPTIdentity
}

extension ChatGPTAuthenticating {
    func verifyRefreshedIdentity(idToken: String, clientID: String, receivedAt: Date?) async throws -> ChatGPTIdentity {
        try await verifyIdentity(idToken: idToken, clientID: clientID, nonce: nil)
    }
}

@MainActor protocol ChatGPTBrowserAuthenticating {
    func authorize(_ request: OAuthBrowserRequest) async throws -> OAuthAuthorization
    func cancel()
}
