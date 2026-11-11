import AuthenticationServices
import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class AuthenticationStore {
    private(set) var accounts: [StoredChatGPTAccount] = []
    private(set) var message: String?
    private var operationInProgress = false

    @ObservationIgnored private let storage = KeychainCredentialStore()
    @ObservationIgnored private let client = ChatGPTAPIClient()
    @ObservationIgnored private let browser = OAuthBrowserSession()
    @ObservationIgnored private var activeID: String?

    var activeAccount: StoredChatGPTAccount? { accounts.first { $0.clientID == activeID } }

    func setWebAuthenticationSession(_ session: WebAuthenticationSession) {
        browser.webAuthenticationSession = session
    }

    /// Cloud connections perform a new local authorization; old device grants are never uploaded.
    func prepareCloudConnection() {
        guard !operationInProgress else { return }
        activeID = nil
    }

    /// The server owns rotation after a successful authenticated handoff. Do not revoke this grant.
    func relinquishCloudConnection(_ clientID: String) throws {
        guard var saved = accounts.first(where: { $0.clientID == clientID }) else { return }
        saved.credentials = nil; saved.pendingRefresh = nil
        try storage.saveAccount(saved)
        try storage.setActiveAccountID(nil)
        upsert(saved); activeID = nil; message = nil
    }

    func signIn(accountID: String? = nil, requestConsent: Bool = false, startNewRegistration: Bool = false) async {
        guard !operationInProgress else { return }
        let previousID = activeID
        let selected = accounts.first { $0.clientID == accountID }
        operationInProgress = true
        defer { operationInProgress = false }
        message = nil
        let operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let hostID = try storage.hostID()
                if startNewRegistration { try storage.setPendingRegistrationClientID(nil) }
                let pendingClientID = selected == nil ? try storage.pendingRegistrationClientID() : nil
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
                guard let token = response.idToken else { throw AuthenticationError.invalidResponse }
                let identity = try await client.verifyIdentity(idToken: token, clientID: authorization.clientID, nonce: authorization.nonce)
                if let selected, selected.identity.issuer != identity.issuer || selected.identity.subject != identity.subject {
                    throw AuthenticationError.invalidIdentity
                }
                try Task.checkCancellation()
                let existing = accounts.first { $0.clientID == authorization.clientID }
                if let existing, existing.identity.issuer != identity.issuer || existing.identity.subject != identity.subject {
                    throw AuthenticationError.invalidIdentity
                }
                let label = existing?.label ?? "Account \((accounts.compactMap { Int($0.label.dropFirst(8)) }.max() ?? 0) + 1)"
                let account = StoredChatGPTAccount(clientID: authorization.clientID, identity: identity, label: label, credentials: response)
                try storage.saveAccount(account)
                if selected == nil { try storage.setPendingRegistrationClientID(nil) }
                upsert(account)
                try activate(account)
            } catch {
                restorePreviousAccount(previousID)
                if !(error is CancellationError), error as? AuthenticationError != .canceled {
                    message = safeMessage(error)
                }
            }
        }
        await operationTask.value
    }

    private func activate(_ account: StoredChatGPTAccount) throws {
        try storage.setActiveAccountID(account.clientID)
        activeID = account.clientID
    }

    private func upsert(_ account: StoredChatGPTAccount) {
        if let index = accounts.firstIndex(where: { $0.clientID == account.clientID }) { accounts[index] = account }
        else { accounts.append(account) }
    }

    private func restorePreviousAccount(_ clientID: String?) {
        activeID = clientID.flatMap { id in accounts.contains { $0.clientID == id && $0.credentials?.idToken != nil } ? id : nil }
    }

    private func safeMessage(_ error: any Error) -> String {
        if let authError = error as? AuthenticationError { return authError.localizedDescription }
        return "Your ChatGPT connection could not be completed. Check your connection and try again."
    }
}
