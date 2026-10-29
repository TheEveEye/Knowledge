import Foundation
import Security

@MainActor
final class KnowledgeSessionKeychain {
    private var query: [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.kiwiapps.knowledge.account",
        kSecAttrAccount as String: "session",
        kSecAttrSynchronizable as String: false,
        kSecUseDataProtectionKeychain as String: true,
    ] }

    func load() throws -> KnowledgeCredentials? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let credentials = try? JSONDecoder().decode(KnowledgeCredentials.self, from: data),
              !credentials.token.isEmpty, credentials.token.count <= 4096 else { throw KnowledgeAccountError.storage }
        return credentials
    }

    func save(_ credentials: KnowledgeCredentials) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(credentials),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            if status == errSecDuplicateItem { status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary) }
        }
        guard status == errSecSuccess else { throw KnowledgeAccountError.storage }
    }

    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KnowledgeAccountError.storage }
    }
}
