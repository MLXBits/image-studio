import Foundation
import Security

enum KeychainHelper {
    private static let service = "MLXBits Image Studio"

    /// kSecUseDataProtectionKeychain opts into the modern iOS-style keychain:
    /// no per-binary-hash ACL binding, so new builds never re-trigger access prompts.
    private static let baseAttributes: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecUseDataProtectionKeychain as String: true,
    ]

    static func set(_ value: String, key: String) {
        var query = baseAttributes
        query[kSecAttrAccount as String] = key
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(_ key: String) -> String {
        var query = baseAttributes
        query[kSecAttrAccount as String] = key
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return "" }
        // Rewrite to migrate legacy items (traditional keychain) into the
        // data-protection keychain so subsequent reads never prompt again.
        set(value, key: key)
        return value
    }
}
