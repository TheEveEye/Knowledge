import Foundation
import Security
import Testing
@testable import Knowledge

@MainActor @Suite("Protected ChatGPT credential persistence")
struct CredentialStoreTests {
    private func account(_ clientID: String = "oaiapp_first") -> StoredChatGPTAccount {
        .init(clientID: clientID, identity: .init(issuer: "https://auth.openai.com", subject: "fixture-subject",
            name: "Fixture", email: "fixture@invalid.test", picture: nil), label: "Connection 1",
            credentials: .init(idToken: "synthetic-id", accessToken: "synthetic-access", refreshToken: "synthetic-refresh",
                expiresAt: Date(timeIntervalSince1970: 1_800_000_000), scopes: ["openid", "offline_access"], earliestRefreshAt: nil))
    }

    @Test func recordsUseDeviceOnlyUnlockedProtectionAndUpdateWithoutDeleting() throws {
        let queries = FixtureKeychain()
        let store = KeychainCredentialStore(service: "fixture.service", keychain: queries)
        let saved = account()
        try store.saveAccount(saved)
        var replacement = saved
        replacement.credentials?.refreshToken = "synthetic-replacement"
        try store.saveAccount(replacement)
        #expect(queries.additions.count == 1)
        #expect(queries.updates.count == 2)
        #expect(queries.deletions.isEmpty)
        let item = try #require(queries.additions.first)
        #expect(item[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(item[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(item[kSecAttrService as String] as? String == "fixture.service")
        #expect(item[kSecAttrAccount as String] as? String == "account.oaiapp_first")
        let loaded = try store.loadAccounts()
        #expect(loaded.count == 1)
        let savedReplacement = loaded.first?.credentials?.refreshToken == replacement.credentials?.refreshToken
        #expect(savedReplacement)
    }

    @Test func sameEmailRegistrationsRemainIndependent() throws {
        let queries = FixtureKeychain()
        let store = KeychainCredentialStore(keychain: queries)
        try store.saveAccount(account())
        try store.saveAccount(account("oaiapp_second"))
        let loaded = try store.loadAccounts()
        #expect(Set(loaded.map(\.clientID)) == Set(["oaiapp_first", "oaiapp_second"]))
        #expect(queries.additions.count == 2)
    }

    @Test func hostIDPersistsAcrossRestartsAndMetadataChanges() throws {
        let queries = FixtureKeychain()
        let store = KeychainCredentialStore(keychain: queries)
        let first = try store.hostID()
        #expect(first.hasPrefix("urn:uuid:"))
        #expect(UUID(uuidString: String(first.dropFirst(9))) != nil)
        try store.setActiveAccountID("oaiapp_first")
        try store.setActiveAccountID(nil)
        let restarted = KeychainCredentialStore(keychain: queries)
        #expect(try restarted.hostID() == first)
        #expect(queries.additions.filter { $0[kSecAttrAccount as String] as? String == "host-id" }.count == 1)
    }

    @Test func metadataDoesNotBecomeAccountAndClearingTargetsOnlyItsKey() throws {
        let queries = FixtureKeychain()
        let store = KeychainCredentialStore(keychain: queries)
        try store.saveAccount(account())
        try store.setActiveAccountID("oaiapp_first")
        try store.setPendingRegistrationClientID("oaiapp_pending")
        _ = try store.hostID()
        #expect(try store.loadAccounts().count == 1)
        #expect(try store.activeAccountID() == "oaiapp_first")
        #expect(try store.pendingRegistrationClientID() == "oaiapp_pending")
        try store.setPendingRegistrationClientID(nil)
        #expect(try store.pendingRegistrationClientID() == nil)
        #expect(try store.activeAccountID() == "oaiapp_first")
        #expect(try store.loadAccounts().count == 1)
        #expect(queries.deletions.allSatisfy { $0[kSecAttrAccount as String] as? String == "pending-registration" })
    }

    @Test func accountEnumerationIgnoresUnrelatedItemPrefixes() throws {
        let queries = FixtureKeychain()
        let store = KeychainCredentialStore(keychain: queries)
        try store.saveAccount(account())
        queries.items["unrelated"] = [kSecAttrAccount as String: "unrelated", kSecValueData as String: Data("unrelated".utf8)]
        #expect(try store.loadAccounts().map(\.clientID) == ["oaiapp_first"])
        let query = try #require(queries.copies.last)
        #expect(query[kSecAttrService as String] as? String == "dev.kiwiapps.knowledge.chatgpt")
        #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String)
    }

    @Test func inaccessibleOrCorruptStorageIsPreservedForRecovery() throws {
        let queries = FixtureKeychain()
        let store = KeychainCredentialStore(keychain: queries)
        try store.saveAccount(account())
        queries.copyError = errSecInteractionNotAllowed
        #expect(throws: AuthenticationError.storage(errSecInteractionNotAllowed)) { try store.loadAccounts() }
        queries.copyError = nil
        queries.items["account.corrupt"] = [kSecAttrAccount as String: "account.corrupt", kSecValueData as String: Data("invalid json".utf8)]
        #expect(throws: AuthenticationError.storage(errSecDecode)) { try store.loadAccounts() }
        #expect(queries.deletions.isEmpty)
        #expect(queries.items.count == 2)
    }

    @Test func failedUpdateDoesNotReplaceExistingCredential() throws {
        let queries = FixtureKeychain()
        let store = KeychainCredentialStore(keychain: queries)
        try store.saveAccount(account())
        queries.updateError = errSecInteractionNotAllowed
        #expect(throws: AuthenticationError.storage(errSecInteractionNotAllowed)) { try store.saveAccount(account()) }
        #expect(queries.additions.count == 1)
        #expect(queries.deletions.isEmpty)
        #expect(queries.items.count == 1)
    }

    @Test func concurrentAdditionRaceRetriesUpdate() throws {
        let queries = FixtureKeychain()
        let store = KeychainCredentialStore(keychain: queries)
        queries.simulateConcurrentAddition = true
        try store.saveAccount(account())
        #expect(queries.updates.count == 2)
        #expect(queries.additions.count == 1)
        #expect(try store.loadAccounts().count == 1)
        #expect(queries.deletions.isEmpty)
    }

    @Test func placeholderRegistrationCannotBePersisted() throws {
        let queries = FixtureKeychain()
        let store = KeychainCredentialStore(keychain: queries)
        #expect(throws: AuthenticationError.storage(errSecParam)) { try store.saveAccount(account("dynamic_agent_client")) }
        #expect(throws: AuthenticationError.storage(errSecParam)) { try store.setPendingRegistrationClientID("dynamic_agent_client") }
        #expect(queries.items.isEmpty)
    }
}

@MainActor private final class FixtureKeychain: KeychainQuerying {
    var items: [String: [String: Any]] = [:]
    var copies: [[String: Any]] = []
    var additions: [[String: Any]] = []
    var updates: [[String: Any]] = []
    var deletions: [[String: Any]] = []
    var copyError: OSStatus?
    var updateError: OSStatus?
    var simulateConcurrentAddition = false

    func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?) {
        copies.append(query)
        if let copyError { return (copyError, nil) }
        if let key = query[kSecAttrAccount as String] as? String {
            guard let item = items[key] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, item[kSecValueData as String])
        }
        guard !items.isEmpty else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, Array(items.values))
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        updates.append(query)
        if let updateError { return updateError }
        guard let key = query[kSecAttrAccount as String] as? String, var existing = items[key] else { return errSecItemNotFound }
        for (attribute, value) in attributes { existing[attribute] = value }
        items[key] = existing
        return errSecSuccess
    }
    func add(_ query: [String: Any]) -> OSStatus {
        additions.append(query)
        guard let key = query[kSecAttrAccount as String] as? String else { return errSecParam }
        if items[key] != nil { return errSecDuplicateItem }
        items[key] = query
        if simulateConcurrentAddition { simulateConcurrentAddition = false; return errSecDuplicateItem }
        return errSecSuccess
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        deletions.append(query)
        guard let key = query[kSecAttrAccount as String] as? String else { return errSecParam }
        return items.removeValue(forKey: key) == nil ? errSecItemNotFound : errSecSuccess
    }
}
