import Foundation
import Testing
@testable import Knowledge

@MainActor @Suite("Authentication session lifecycle")
struct AuthenticationStoreTests {
    private func identity(_ subject: String = "subject") -> ChatGPTIdentity {
        .init(issuer: "https://auth.openai.com", subject: subject, name: "Example", email: "example@invalid.test", picture: nil)
    }

    private func credentials(expired: Bool = false, plan: Bool = true) -> ChatGPTCredentials {
        .init(idToken: "test-id", accessToken: plan ? "test-access" : nil,
              refreshToken: plan ? "test-refresh" : nil,
              expiresAt: plan ? Date().addingTimeInterval(expired ? -120 : 3600) : nil,
              scopes: plan ? ["openid", "offline_access", ChatGPTConfiguration.planScope] : ["openid", "email"], earliestRefreshAt: nil)
    }

    private func account(_ id: String = "oaiapp_test", expired: Bool = false, plan: Bool = true) -> StoredChatGPTAccount {
        .init(clientID: id, identity: identity(), label: "Account 1", credentials: credentials(expired: expired, plan: plan))
    }

    @Test func loginWithoutPlanPermissionStillOpensApp() async {
        let storage = MemoryCredentialStorage()
        let client = TestAuthenticationClient(identity: identity(), response: credentials(plan: false))
        let store = AuthenticationStore(storage: storage, client: client, browser: TestAuthenticationBrowser())
        await store.restore()
        await store.signIn()
        #expect(store.state == .signedIn("oaiapp_test"))
        #expect(store.activeAccount?.credentials?.planEnabled == false)
        #expect(storage.savedAccounts.count == 1)
    }

    @Test func keychainFailureKeepsLoginClosed() async {
        let storage = MemoryCredentialStorage()
        storage.error = .storage(-1)
        let store = AuthenticationStore(storage: storage, client: TestAuthenticationClient(identity: identity(), response: credentials()), browser: TestAuthenticationBrowser())
        await store.restore()
        #expect(store.state == .recovery)
        #expect(store.message != nil)
    }

    @Test func failedAccountSwitchPreservesActiveAccount() async {
        let first = account()
        let second = account("oaiapp_second", expired: true)
        let storage = MemoryCredentialStorage(accounts: [first, second], activeID: first.clientID)
        let client = TestAuthenticationClient(identity: identity(), response: credentials())
        client.refreshError = URLError(.notConnectedToInternet)
        let store = AuthenticationStore(storage: storage, client: client, browser: TestAuthenticationBrowser())
        await store.restore()
        await store.selectAccount(second.clientID)
        #expect(store.activeAccount?.clientID == first.clientID)
        #expect(store.state == .signedIn(first.clientID))
        #expect(storage.savedAccounts[second.clientID]?.credentials != nil)
    }

    @Test func signOutClearsTokensButRetainsRegistration() async {
        let saved = account()
        let storage = MemoryCredentialStorage(accounts: [saved], activeID: saved.clientID)
        let client = TestAuthenticationClient(identity: identity(), response: credentials())
        client.revokeError = URLError(.notConnectedToInternet)
        let store = AuthenticationStore(storage: storage, client: client, browser: TestAuthenticationBrowser())
        await store.restore()
        await store.signOut()
        #expect(store.state == .signedOut)
        #expect(storage.savedAccounts[saved.clientID]?.credentials == nil)
        #expect(storage.savedAccounts[saved.clientID]?.identity == saved.identity)
        #expect(storage.selectedID == nil)
        #expect(store.message?.contains("Remote revocation") == true)
        #expect(client.revokeCount == 1)
    }

    @Test func terminalRefreshFailureClearsUnusableCredentials() async {
        let saved = account(expired: true)
        let storage = MemoryCredentialStorage(accounts: [saved], activeID: saved.clientID)
        let client = TestAuthenticationClient(identity: identity(), response: credentials())
        client.refreshError = AuthenticationError.oauth("refresh_token_reused")
        let store = AuthenticationStore(storage: storage, client: client, browser: TestAuthenticationBrowser())
        await store.restore()
        #expect(storage.savedAccounts[saved.clientID]?.credentials == nil)
        #expect(store.activeAccount == nil)
        #expect(store.state == .recovery)
    }

    @Test func rotatedCredentialsSurviveTemporaryVerificationFailure() async throws {
        let saved = account(expired: true)
        let storage = MemoryCredentialStorage(accounts: [saved], activeID: saved.clientID)
        var renewed = credentials()
        renewed.refreshToken = "replacement-refresh"
        let client = TestAuthenticationClient(identity: identity(), response: renewed)
        client.verificationError = URLError(.networkConnectionLost)
        let store = AuthenticationStore(storage: storage, client: client, browser: TestAuthenticationBrowser())
        await store.restore()
        #expect(storage.savedAccounts[saved.clientID]?.pendingRefresh?.refreshToken == "replacement-refresh")
        #expect(client.refreshCount == 1)
        client.verificationError = nil
        await store.retryRestoration()
        #expect(store.state == .signedIn(saved.clientID))
        #expect(storage.savedAccounts[saved.clientID]?.pendingRefresh == nil)
        #expect(storage.savedAccounts[saved.clientID]?.credentials?.refreshToken == "replacement-refresh")
        #expect(client.refreshCount == 1)
    }

    @Test func concurrentTokenRequestsUseOneRefresh() async throws {
        let saved = account()
        let storage = MemoryCredentialStorage(accounts: [saved], activeID: saved.clientID)
        var clock = Date()
        var renewed = credentials()
        renewed.expiresAt = clock.addingTimeInterval(7200)
        let client = TestAuthenticationClient(identity: identity(), response: renewed)
        let store = AuthenticationStore(storage: storage, client: client, browser: TestAuthenticationBrowser(), now: { clock })
        await store.restore()
        clock = clock.addingTimeInterval(3601)
        client.holdRefresh = true
        let first = Task { try await store.authorizedAccessToken() }
        await client.waitForRefresh()
        let second = Task { try await store.authorizedAccessToken() }
        await Task.yield()
        client.completeRefresh()
        let firstToken = try await first.value
        let secondToken = try await second.value
        #expect(firstToken == secondToken)
        #expect(client.refreshCount == 1)
        #expect(store.activeAccount?.credentials?.planEnabled == true)
    }

    @Test func terminalCleanupLeavesAppClosedWhenActiveMetadataWriteFails() async {
        let saved = account()
        let storage = MemoryCredentialStorage(accounts: [saved], activeID: saved.clientID)
        var clock = Date()
        let client = TestAuthenticationClient(identity: identity(), response: credentials())
        let store = AuthenticationStore(storage: storage, client: client, browser: TestAuthenticationBrowser(), now: { clock })
        await store.restore()
        clock = clock.addingTimeInterval(3601)
        storage.activeError = .storage(-1)
        client.refreshError = AuthenticationError.oauth("invalid_grant")
        do { _ = try await store.authorizedAccessToken(); Issue.record("Terminal refresh must fail") } catch { }
        #expect(store.activeAccount == nil)
        #expect(store.state == .recovery)
        #expect(storage.savedAccounts[saved.clientID]?.credentials == nil)
        storage.activeError = nil
        await store.retryRestoration()
        #expect(store.state == .signedOut)
    }

    @Test func rotatedTokensStayInMemoryWhenCheckpointWriteFails() async {
        let saved = account(expired: true)
        let storage = MemoryCredentialStorage(accounts: [saved], activeID: saved.clientID)
        var renewed = credentials()
        renewed.refreshToken = "replacement-after-write-failure"
        let client = TestAuthenticationClient(identity: identity(), response: renewed)
        storage.saveError = .storage(-1)
        let store = AuthenticationStore(storage: storage, client: client, browser: TestAuthenticationBrowser())
        await store.restore()
        #expect(store.accounts.first?.pendingRefresh?.refreshToken == renewed.refreshToken)
        storage.saveError = nil
        await store.retryRestoration()
        #expect(client.refreshCount == 1)
        #expect(store.activeAccount?.credentials?.refreshToken == renewed.refreshToken)
    }

    @Test func reauthorizationWaitsForOlderRefreshBeforeCommitting() async throws {
        let saved = account()
        let storage = MemoryCredentialStorage(accounts: [saved], activeID: saved.clientID)
        var clock = Date()
        var refreshed = credentials()
        refreshed.accessToken = "old-grant-refreshed"
        refreshed.expiresAt = clock.addingTimeInterval(7200)
        let client = TestAuthenticationClient(identity: identity(), response: refreshed)
        var newGrant = credentials()
        newGrant.accessToken = "newly-authorized-grant"
        client.exchangeResponse = newGrant
        let store = AuthenticationStore(storage: storage, client: client, browser: TestAuthenticationBrowser(), now: { clock })
        await store.restore()
        clock = clock.addingTimeInterval(3601)
        client.holdRefresh = true
        let refresh = Task { try await store.authorizedAccessToken() }
        await client.waitForRefresh()
        let reauthorize = Task { await store.signIn(accountID: saved.clientID, requestConsent: true) }
        await Task.yield()
        #expect(client.exchangeCount == 0)
        client.completeRefresh()
        _ = try? await refresh.value
        await reauthorize.value
        #expect(client.refreshCount == 1)
        #expect(client.exchangeCount == 1)
        #expect(store.activeAccount?.pendingRefresh == nil)
        #expect(store.activeAccount?.credentials?.accessToken == "newly-authorized-grant")
    }

    @Test func canceledSignInCannotRestoreSessionAfterLogout() async {
        let storage = MemoryCredentialStorage()
        let client = TestAuthenticationClient(identity: identity(), response: credentials())
        let browser = TestAuthenticationBrowser()
        browser.holdAuthorization = true
        let store = AuthenticationStore(storage: storage, client: client, browser: browser)
        await store.restore()
        let login = Task { await store.signIn() }
        await browser.waitForAuthorization()
        await store.signOut()
        browser.completeAuthorization()
        await login.value
        #expect(store.state == .signedOut)
        #expect(storage.savedAccounts.isEmpty)
        #expect(client.exchangeCount == 0)
    }

    @Test func incompleteRegistrationReusesIssuedClientID() async {
        let storage = MemoryCredentialStorage()
        let client = TestAuthenticationClient(identity: identity(), response: credentials())
        client.exchangeError = AuthenticationError.oauth("invalid_grant")
        let browser = TestAuthenticationBrowser()
        let store = AuthenticationStore(storage: storage, client: client, browser: browser)
        await store.restore()
        await store.signIn()
        #expect(storage.pendingID == "oaiapp_test")
        #expect(storage.savedAccounts.isEmpty)
        client.exchangeError = nil
        await store.signIn()
        #expect(browser.requests.last?.registrationClientID == "oaiapp_test")
        #expect(storage.pendingID == nil)
        #expect(store.state == .signedIn("oaiapp_test"))
    }

    @Test func signOutStorageFailureCanBeRetried() async {
        let saved = account()
        let storage = MemoryCredentialStorage(accounts: [saved], activeID: saved.clientID)
        let client = TestAuthenticationClient(identity: identity(), response: credentials())
        let store = AuthenticationStore(storage: storage, client: client, browser: TestAuthenticationBrowser())
        await store.restore()
        storage.saveError = .storage(-1)
        await store.signOut()
        #expect(store.state == .recovery)
        #expect(store.activeAccount == nil)
        storage.saveError = nil
        await store.retryRestoration()
        #expect(store.state == .signedOut)
        #expect(storage.savedAccounts[saved.clientID]?.credentials == nil)
        #expect(client.revokeCount == 2)
    }

    @Test func returningAccountMustMatchVerifiedIdentity() async {
        let saved = account()
        let storage = MemoryCredentialStorage(accounts: [saved])
        let client = TestAuthenticationClient(identity: identity("different-subject"), response: credentials())
        let store = AuthenticationStore(storage: storage, client: client, browser: TestAuthenticationBrowser())
        await store.restore()
        await store.signIn(accountID: saved.clientID)
        #expect(store.state == .signedOut)
        #expect(storage.savedAccounts[saved.clientID]?.identity == saved.identity)
    }
}

@MainActor final class MemoryCredentialStorage: ChatGPTCredentialStorage {
    var savedAccounts: [String: StoredChatGPTAccount]
    var selectedID: String?
    var pendingID: String?
    var error: AuthenticationError?
    var saveError: AuthenticationError?
    var activeError: AuthenticationError?
    init(accounts: [StoredChatGPTAccount] = [], activeID: String? = nil) {
        savedAccounts = Dictionary(uniqueKeysWithValues: accounts.map { ($0.clientID, $0) })
        selectedID = activeID
    }
    func pendingRegistrationClientID() throws -> String? { pendingID }
    func setPendingRegistrationClientID(_ clientID: String?) throws { pendingID = clientID }
    func hostID() throws -> String { if let error { throw error }; return "urn:uuid:test-host" }
    func loadAccounts() throws -> [StoredChatGPTAccount] { if let error { throw error }; return savedAccounts.values.sorted { $0.clientID < $1.clientID } }
    func saveAccount(_ account: StoredChatGPTAccount) throws { if let error { throw error }; if let saveError { throw saveError }; savedAccounts[account.clientID] = account }
    func activeAccountID() throws -> String? { if let error { throw error }; return selectedID }
    func setActiveAccountID(_ clientID: String?) throws { if let error { throw error }; if let activeError { throw activeError }; selectedID = clientID }
}

@MainActor final class TestAuthenticationClient: ChatGPTAuthenticating {
    var identity: ChatGPTIdentity
    var response: ChatGPTCredentials
    var refreshError: (any Error)?
    var exchangeError: (any Error)?
    var exchangeResponse: ChatGPTCredentials?
    var verificationError: (any Error)?
    var revokeError: (any Error)?
    var refreshCount = 0
    var exchangeCount = 0
    var revokeCount = 0
    var holdRefresh = false
    private var refreshContinuation: CheckedContinuation<Void, Never>?
    private var refreshStarted: CheckedContinuation<Void, Never>?
    init(identity: ChatGPTIdentity, response: ChatGPTCredentials) { self.identity = identity; self.response = response }
    func authorizationEndpoint() async throws -> URL { URL(string: "https://auth.openai.com/api/accounts/authorize")! }
    func exchange(_ authorization: OAuthAuthorization) async throws -> OAuthTokenResponse { exchangeCount += 1; if let exchangeError { throw exchangeError }; return .init(credentials: exchangeResponse ?? response) }
    func refresh(_ account: StoredChatGPTAccount) async throws -> OAuthTokenResponse {
        refreshCount += 1
        if holdRefresh {
            await withCheckedContinuation { continuation in
                refreshContinuation = continuation
                refreshStarted?.resume()
                refreshStarted = nil
            }
        }
        if let refreshError { throw refreshError }
        return .init(credentials: response)
    }
    func waitForRefresh() async { if refreshContinuation != nil { return }; await withCheckedContinuation { refreshStarted = $0 } }
    func completeRefresh() { refreshContinuation?.resume(); refreshContinuation = nil }
    func verifyIdentity(idToken: String, clientID: String, nonce: String?) async throws -> ChatGPTIdentity { if let verificationError { throw verificationError }; return identity }
    func revoke(_ account: StoredChatGPTAccount) async throws { revokeCount += 1; if let revokeError { throw revokeError } }
}

@MainActor final class TestAuthenticationBrowser: ChatGPTBrowserAuthenticating {
    var holdAuthorization = false
    var requests: [OAuthBrowserRequest] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func authorize(_ request: OAuthBrowserRequest) async throws -> OAuthAuthorization {
        requests.append(request)
        if holdAuthorization {
            await withCheckedContinuation { value in continuation = value; started?.resume(); started = nil }
        }
        return .init(code: "test-code", clientID: request.account?.clientID ?? request.registrationClientID ?? "oaiapp_test", verifier: "test-verifier", nonce: "test-nonce", redirectURI: URL(string: "http://127.0.0.1:12345/auth/callback")!)
    }
    func cancel() { }
    func waitForAuthorization() async { if continuation != nil { return }; await withCheckedContinuation { started = $0 } }
    func completeAuthorization() { continuation?.resume(); continuation = nil }
}
