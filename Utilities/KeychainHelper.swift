import Foundation
import Security

enum KeychainHelper {
    /// The accounts the app stores. ``migrateLegacyItemsOnce(defaults:)`` moves these.
    static let accounts = ["hf_token", "openai_api_key"]

    private static let service = "MLXBits Image Studio"
    private static let migrationFlagPrefix = "keychainLegacyItemMigrated."

    /// kSecUseDataProtectionKeychain opts into the modern iOS-style keychain:
    /// no per-binary-hash ACL binding, so new builds never re-trigger access prompts.
    private static let baseAttributes: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecUseDataProtectionKeychain as String: true,
    ]

    /// Replaces the item for `key`; an empty value only deletes it. Returns the
    /// `SecItemAdd` status, or `errSecSuccess` for a delete.
    @discardableResult
    static func set(_ value: String, key: String) -> OSStatus {
        var query = baseAttributes
        query[kSecAttrAccount as String] = key
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return errSecSuccess }
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil)
    }

    static func get(_ key: String) -> String {
        read(key, dataProtection: true) ?? ""
    }

    /// Moves items that builds before June 2026 wrote to the file-based keychain
    /// into the data-protection keychain. A read of a legacy item can show the
    /// system's keychain-access prompt, so each account is marked done once it has
    /// been handled and is never looked up again; an account that already has a
    /// data-protection item is not looked up at all. An account whose copy fails
    /// keeps its legacy item and is retried on the next launch.
    static func migrateLegacyItemsOnce(defaults: UserDefaults = .standard) {
        for key in accounts where !defaults.bool(forKey: migrationFlagPrefix + key) {
            if read(key, dataProtection: true) == nil, let legacy = read(key, dataProtection: false) {
                guard set(legacy, key: key) == errSecSuccess else { continue }
                var query = baseAttributes
                query[kSecAttrAccount as String] = key
                query[kSecUseDataProtectionKeychain as String] = false
                SecItemDelete(query as CFDictionary)
            }
            defaults.set(true, forKey: migrationFlagPrefix + key)
        }
    }

    private static func read(_ key: String, dataProtection: Bool) -> String? {
        var query = baseAttributes
        query[kSecAttrAccount as String] = key
        query[kSecUseDataProtectionKeychain as String] = dataProtection
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }
}
