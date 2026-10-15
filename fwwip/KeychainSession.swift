import Foundation
import Security

/// Only FWWIP's own item. No global token search, shared access group, or iCloud sync.
@MainActor
final class KeychainSession {
    private let account: String
    init(account: String = "FWWIP.native-session") { self.account = account }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: OAuthPolicy.keychainService,
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: false]
    }
    func verifyPrivateStorage() throws {
        // Separate synthetic item; never overwrite a real session when checking signing support.
        let probe = KeychainSession(account: "FWWIP.storage-probe")
        defer { try? probe.delete() }
        let marker = OAuthTokens(access: "FWWIP-storage-check-" + UUID().uuidString, refresh: nil, expiresAt: .now)
        try probe.save(marker)
        let loaded = try probe.load()
        guard loaded?.access == marker.access else { throw OAuthIssue.storage }
        try probe.delete()
    }
    func load() throws -> OAuthTokens? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw OAuthIssue.storageStatus(status) }
        guard let data = result as? Data,
              let tokens = try? JSONDecoder().decode(OAuthTokens.self, from: data) else { throw OAuthIssue.storage }
        return tokens
    }
    func save(_ tokens: OAuthTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item.merge(attributes) { _, new in new }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw OAuthIssue.storageStatus(added) }
        } else if status != errSecSuccess { throw OAuthIssue.storageStatus(status) }
    }
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw OAuthIssue.storageStatus(status) }
    }
}
