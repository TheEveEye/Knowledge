import Foundation
import Observation
import UIKit

nonisolated enum AuthenticationState: Equatable {
    case restoring, signedOut, signingIn, signedIn(String), recovery
}

@MainActor @Observable
final class AuthenticationStore {
    private(set) var state: AuthenticationState = .restoring
    private(set) var accounts: [StoredChatGPTAccount] = []
    private(set) var message: String?
    private(set) var planWelcomeAccountID: String?
    private var operationInProgress = false

    @ObservationIgnored private let storage: any ChatGPTCredentialStorage
    @ObservationIgnored private let client: any ChatGPTAuthenticating
    @ObservationIgnored private let browser: any ChatGPTBrowserAuthenticating
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var operationID = UUID()
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTasks: [String: Task<StoredChatGPTAccount, Error>] = [:]
    @ObservationIgnored private var refreshGenerations: [String: UUID] = [:]
    @ObservationIgnored private var activeID: String?
    @ObservationIgnored private var didRestore = false
    private var signingOut = false
    @ObservationIgnored private var pendingSignOutID: String?
    @ObservationIgnored private var pendingSignOutAccount: StoredChatGPTAccount?

    init(storage: (any ChatGPTCredentialStorage)? = nil,
         client: (any ChatGPTAuthenticating)? = nil,
         browser: (any ChatGPTBrowserAuthenticating)? = nil,
         now: @escaping @MainActor () -> Date = { Date() }) {
        self.storage = storage ?? KeychainCredentialStore()
        self.client = client ?? ChatGPTAPIClient()
        self.browser = browser ?? OAuthBrowserSession()
        self.now = now
    }

    var activeAccount: StoredChatGPTAccount? { accounts.first { $0.clientID == activeID } }
    var isBusy: Bool { state == .restoring || state == .signingIn || signingOut || operationInProgress }

    func setPresentationAnchor(_ window: UIWindow) {
        (browser as? OAuthBrowserSession)?.presentationAnchor = window
    }

    func restore() async {
        guard !didRestore else { return }
        didRestore = true
        let attempt = operationID
        do {
            _ = try storage.hostID()
            let previousAccounts = accounts
            accounts = try storage.loadAccounts().map { stored in
                if let pending = previousAccounts.first(where: { $0.clientID == stored.clientID && $0.identity == stored.identity }), pending.pendingRefresh != nil { return pending }
                return stored
            }
            guard let savedID = try storage.activeAccountID(),
                  let saved = accounts.first(where: { $0.clientID == savedID }),
                  saved.credentials?.idToken != nil else {
                state = .signedOut
                return
            }
            let account = try await resumedAccount(saved)
            guard operationID == attempt else { return }
            try activate(account)
        } catch {
            guard operationID == attempt else { return }
            state = .recovery
            message = safeMessage(error)
        }
    }

    func retryRestoration() async {
        guard !isBusy else { return }
        if pendingSignOutID != nil { await signOut(); return }
        didRestore = false
        state = .restoring
        message = nil
        await restore()
    }

    func signIn(accountID: String? = nil, requestConsent: Bool = false, startNewRegistration: Bool = false) async {
        if pendingSignOutID != nil { await signOut(); guard pendingSignOutID == nil else { return } }
        guard !isBusy else { return }
        let previousID = activeID
        let selected = accounts.first { $0.clientID == accountID }
        let attempt = UUID()
        operationID = attempt
        state = .signingIn
        operationInProgress = true
        message = nil
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let hostID = try storage.hostID()
                if startNewRegistration { try storage.setPendingRegistrationClientID(nil) }
                let pendingClientID = selected == nil ? try storage.pendingRegistrationClientID() : nil
                if let selected, let refresh = refreshTasks[selected.clientID] { _ = await refresh.result }
                try Task.checkCancellation()
                let selectedForRequest = selected.flatMap { selected in self.accounts.first { $0.clientID == selected.clientID } }
                let endpoint = try await client.authorizationEndpoint()
                try Task.checkCancellation()
                let authorization = try await browser.authorize(.init(
                    authorizationEndpoint: endpoint, hostID: hostID,
                    account: selectedForRequest, requestConsent: requestConsent, registrationClientID: pendingClientID))
                try Task.checkCancellation()
                if selected == nil { try storage.setPendingRegistrationClientID(authorization.clientID) }
                let response = try await client.exchange(authorization)
                guard let token = response.credentials.idToken else { throw AuthenticationError.invalidResponse }
                let identity = try await client.verifyIdentity(idToken: token, clientID: authorization.clientID, nonce: authorization.nonce)
                if let selected, selected.identity.issuer != identity.issuer || selected.identity.subject != identity.subject {
                    throw AuthenticationError.invalidIdentity
                }
                try Task.checkCancellation()
                guard operationID == attempt else { return }
                let existing = accounts.first { $0.clientID == authorization.clientID }
                if let existing, existing.identity.issuer != identity.issuer || existing.identity.subject != identity.subject {
                    throw AuthenticationError.invalidIdentity
                }
                let label = existing?.label ?? "Account \((accounts.compactMap { Int($0.label.dropFirst(8)) }.max() ?? 0) + 1)"
                let account = StoredChatGPTAccount(clientID: authorization.clientID, identity: identity, label: label, credentials: response.credentials)
                refreshGenerations[account.clientID] = UUID()
                try storage.saveAccount(account)
                if selected == nil { try storage.setPendingRegistrationClientID(nil) }
                upsert(account)
                try activate(account)
                if account.credentials?.planEnabled == true && existing?.credentials?.planEnabled != true {
                    showPlanWelcomeIfNeeded(account.clientID)
                }
            } catch {
                guard operationID == attempt else { return }
                restorePreviousAccount(previousID)
                if !(error is CancellationError), error as? AuthenticationError != .canceled {
                    message = safeMessage(error)
                }
            }
            if operationID == attempt { operationTask = nil; operationInProgress = false }
        }
        await operationTask?.value
    }

    func selectAccount(_ clientID: String) async {
        if pendingSignOutID != nil { await signOut(); guard pendingSignOutID == nil else { return } }
        guard !isBusy, let saved = accounts.first(where: { $0.clientID == clientID }) else { return }
        guard saved.credentials?.idToken != nil else {
            await signIn(accountID: clientID)
            return
        }
        let attempt = UUID()
        operationID = attempt
        let previousID = activeID
        state = .signingIn
        operationInProgress = true
        message = nil
        defer { if operationID == attempt { operationInProgress = false } }
        do {
            let account = try await resumedAccount(saved)
            guard operationID == attempt else { return }
            try activate(account)
        } catch {
            guard operationID == attempt else { return }
            restorePreviousAccount(previousID)
            message = safeMessage(error)
            if let authError = error as? AuthenticationError, authError.isTerminalRefreshError {
                await signIn(accountID: clientID)
            }
        }
    }

    /// Future AI requests can obtain a scoped token without exposing it to views.
    func authorizedAccessToken() async throws -> String {
        guard !signingOut, let account = activeAccount, account.credentials?.planEnabled == true else {
            throw AuthenticationError.sessionExpired
        }
        let attempt = operationID
        let renewed = try await resumedAccount(account)
        guard operationID == attempt, activeID == renewed.clientID, !signingOut,
              renewed.credentials?.planEnabled == true,
              let token = renewed.credentials?.accessToken else { throw AuthenticationError.sessionExpired }
        return token
    }

    private func resumedAccount(_ account: StoredChatGPTAccount) async throws -> StoredChatGPTAccount {
        if account.pendingRefresh == nil,
           account.credentials?.accessToken == nil || (account.credentials?.expiresAt ?? .distantPast) > now().addingTimeInterval(60) {
            return account
        }
        if let task = refreshTasks[account.clientID] { return try await task.value }
        guard account.pendingRefresh != nil || account.credentials?.refreshToken != nil else {
            try clearTokens(for: account)
            throw AuthenticationError.sessionExpired
        }
        let generation = refreshGenerations[account.clientID] ?? UUID()
        refreshGenerations[account.clientID] = generation
        let task = Task { [self] () throws -> StoredChatGPTAccount in
            var updated = account
            do {
                let response: ChatGPTCredentials
                if let pending = account.pendingRefresh {
                    response = pending
                } else {
                    response = try await client.refresh(account).credentials
                    // A consumed rotating grant must be checkpointed before JWKS retrieval.
                    guard refreshGenerations[account.clientID] == generation else { throw CancellationError() }
                }
                updated.pendingRefresh = response
                upsert(updated)
                try storage.saveAccount(updated)
                if let token = response.idToken {
                    let identity = try await client.verifyRefreshedIdentity(idToken: token, clientID: account.clientID, receivedAt: response.receivedAt)
                    guard identity.issuer == account.identity.issuer, identity.subject == account.identity.subject else {
                        throw AuthenticationError.invalidIdentity
                    }
                }
                try Task.checkCancellation()
                guard refreshGenerations[account.clientID] == generation else { throw CancellationError() }
                var credentials = response
                credentials.idToken = response.idToken ?? account.credentials?.idToken
                updated.credentials = credentials
                updated.pendingRefresh = nil
                try storage.saveAccount(updated)
                upsert(updated)
                return updated
            } catch {
                if refreshGenerations[account.clientID] == generation,
                   let authError = error as? AuthenticationError,
                   authError.isTerminalRefreshError || authError == .invalidIdentity {
                    try clearTokens(for: updated)
                }
                throw error
            }
        }
        refreshTasks[account.clientID] = task
        defer { refreshTasks.removeValue(forKey: account.clientID) }
        return try await task.value
    }

    func signOut() async {
        guard !signingOut else { return }
        signingOut = true
        defer { signingOut = false }
        operationID = UUID()
        operationTask?.cancel()
        operationTask = nil
        operationInProgress = false
        browser.cancel()
        message = nil
        planWelcomeAccountID = nil
        let signingOutID = activeID ?? pendingSignOutID ?? (try? storage.activeAccountID())
        pendingSignOutID = signingOutID
        activeID = nil
        state = .signedOut
        do {
            var storageError: (any Error)?
            do { try storage.setActiveAccountID(nil) } catch { storageError = error }
            guard let signingOutID else {
                if let storageError { throw storageError }
                return
            }
            // Wait for any rotation so revocation targets the newest renewable session.
            if let refreshing = refreshTasks[signingOutID] {
                _ = await refreshing.result
            }
            guard let account = accounts.first(where: { $0.clientID == signingOutID }) else { return }
            var revoked = true
            let current = account.credentials == nil ? (pendingSignOutAccount ?? account) : account
            let newest = current.pendingRefresh.map { pending in
                var value = current
                value.credentials = pending
                return value
            } ?? current
            pendingSignOutAccount = newest
            if newest.credentials?.refreshToken != nil {
                do { try await client.revoke(newest) }
                catch { revoked = false }
            }
            refreshGenerations[signingOutID] = UUID()
            try clearTokens(for: account)
            if let storageError { throw storageError }
            pendingSignOutID = nil
            pendingSignOutAccount = nil
            if !revoked {
                message = "You’re signed out here. Remote revocation could not be confirmed. Disconnect Knowledge in ChatGPT’s Security and login settings to end remote access."
            }
        } catch {
            state = .recovery
            message = "Sign-out could not clear the saved credentials securely. Please retry."
        }
    }

    func sceneDidEnterBackground() {
        guard state == .signingIn || operationInProgress else { return }
        operationID = UUID()
        operationTask?.cancel()
        operationTask = nil
        operationInProgress = false
        browser.cancel()
        state = activeID.map(AuthenticationState.signedIn) ?? .signedOut
        message = AuthenticationError.backgrounded.localizedDescription
    }

    func dismissMessage() { message = nil }
    func dismissPlanWelcome() { planWelcomeAccountID = nil }

    private func showPlanWelcomeIfNeeded(_ clientID: String) {
        let key = "ChatGPTPlanWelcome.\(clientID)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        planWelcomeAccountID = clientID
    }

    private func activate(_ account: StoredChatGPTAccount) throws {
        try storage.setActiveAccountID(account.clientID)
        activeID = account.clientID
        state = .signedIn(account.clientID)
    }

    private func upsert(_ account: StoredChatGPTAccount) {
        if let index = accounts.firstIndex(where: { $0.clientID == account.clientID }) { accounts[index] = account }
        else { accounts.append(account) }
    }

    private func clearTokens(for account: StoredChatGPTAccount) throws {
        var cleared = account
        cleared.credentials = nil
        cleared.pendingRefresh = nil
        let wasActive = activeID == account.clientID
        upsert(cleared)
        if wasActive {
            activeID = nil
            state = .signedOut
        }
        do {
            try storage.saveAccount(cleared)
            if wasActive { try storage.setActiveAccountID(nil) }
        } catch {
            if wasActive { state = .recovery; message = safeMessage(error) }
            throw error
        }
    }

    private func restorePreviousAccount(_ clientID: String?) {
        activeID = clientID.flatMap { id in accounts.contains { $0.clientID == id && $0.credentials?.idToken != nil } ? id : nil }
        state = activeID.map(AuthenticationState.signedIn) ?? .signedOut
    }

    private func safeMessage(_ error: any Error) -> String {
        if let authError = error as? AuthenticationError { return authError.localizedDescription }
        return "Your ChatGPT connection could not be completed. Check your connection and try again."
    }
}
