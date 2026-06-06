import Foundation
import Security

enum KeychainHelper {
    private static let service = "MLXBits Image Studio"

    static func set(_ value: String, key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        // SecAccess with nil trusted apps allows any application signed with
        // our certificate to read the item without a keychain password prompt.
        // The default ACL binds access to the specific binary hash, so every
        // new build re-triggers "wants to use your confidential information".
        var access: SecAccess?
        if SecAccessCreate(service as CFString, nil, &access) == errSecSuccess, let access {
            attributes[kSecAttrAccess as String] = access
        } else {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func get(_ key: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return "" }
        // Rewrite with the permissive SecAccess ACL so subsequent reads on
        // any build never prompt again (one-time migration for existing items).
        set(value, key: key)
        return value
    }
}
