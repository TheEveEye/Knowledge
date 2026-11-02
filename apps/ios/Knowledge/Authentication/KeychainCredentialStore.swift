import Foundation
import Security

@MainActor
final class KeychainCredentialStore {
    private let service = "dev.kiwiapps.knowledge.chatgpt"
    private let accountPrefix = "account."

    func hostID() throws -> String {
        if let data = try read("host-id") {
            guard let value = String(data: data, encoding: .utf8), value.hasPrefix("urn:uuid:"),
                  UUID(uuidString: String(value.dropFirst("urn:uuid:".count))) != nil else {
                throw AuthenticationError.storage(errSecDecode)
            }
            return value
        }
        let value = "urn:uuid:" + UUID().uuidString.lowercased()
        try write(Data(value.utf8), account: "host-id")
        return value
    }

    func loadAccounts() throws -> [StoredChatGPTAccount] {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw AuthenticationError.storage(status) }
        guard let items = result as? [[String: Any]] else { throw AuthenticationError.storage(errSecDecode) }
        var accounts: [StoredChatGPTAccount] = []
        for item in items {
            guard let key = item[kSecAttrAccount as String] as? String else { throw AuthenticationError.storage(errSecDecode) }
            guard key.hasPrefix(accountPrefix) else { continue }
            guard let data = item[kSecValueData as String] as? Data,
                  let account = try? JSONDecoder().decode(StoredChatGPTAccount.self, from: data),
                  account.clientID == String(key.dropFirst(accountPrefix.count)), validClientID(account.clientID) else {
                // Leave corrupt or unavailable storage in place for recovery.
                throw AuthenticationError.storage(errSecDecode)
            }
            accounts.append(account)
        }
        return accounts.sorted {
            $0.label == $1.label ? $0.clientID < $1.clientID : $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
    }

    func saveAccount(_ account: StoredChatGPTAccount) throws {
        guard validClientID(account.clientID) else { throw AuthenticationError.storage(errSecParam) }
        guard let data = try? JSONEncoder().encode(account) else { throw AuthenticationError.storage(errSecParam) }
        try write(data, account: accountPrefix + account.clientID)
    }

    func activeAccountID() throws -> String? { try readClientID("active-account") }
    func setActiveAccountID(_ clientID: String?) throws { try writeClientID(clientID, account: "active-account") }

    func pendingRegistrationClientID() throws -> String? { try readClientID("pending-registration") }
    func setPendingRegistrationClientID(_ clientID: String?) throws { try writeClientID(clientID, account: "pending-registration") }

    private func readClientID(_ key: String) throws -> String? {
        guard let data = try read(key) else { return nil }
        guard let value = String(data: data, encoding: .utf8), validClientID(value) else {
            throw AuthenticationError.storage(errSecDecode)
        }
        return value
    }

    private func writeClientID(_ clientID: String?, account: String) throws {
        if let clientID {
            guard validClientID(clientID) else { throw AuthenticationError.storage(errSecParam) }
            try write(Data(clientID.utf8), account: account)
        } else {
            let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AuthenticationError.storage(status) }
        }
    }

    private func read(_ account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AuthenticationError.storage(status) }
        guard let data = result as? Data else { throw AuthenticationError.storage(errSecDecode) }
        return data
    }

    private func write(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Imports may refresh and persist rotating credentials while the screen is locked.
            // Non-credential installation metadata still requires an unlocked device.
            kSecAttrAccessible as String: account.hasPrefix(accountPrefix)
                ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            if status == errSecDuplicateItem { status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary) }
        }
        guard status == errSecSuccess else { throw AuthenticationError.storage(status) }
    }

    private func baseQuery(account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    private func validClientID(_ value: String) -> Bool {
        value != "dynamic_agent_client" && value.range(of: "^[a-zA-Z0-9_-]{1,200}$", options: .regularExpression) != nil
    }
}
