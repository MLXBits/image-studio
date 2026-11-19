import Foundation
import Security

enum KeychainHelper {
    /// The accounts the app stores. ``migrateLegacyItemsOnce(defaults:)`` moves these.
    static let accounts = ["hf_token", "openai_api_key"]

    private static let service = "MLXBits Image Studio"
    private static let migrationFlag = "keychainLegacyItemsMigrated"

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
        read(key, dataProtection: true) ?? ""
    }

    /// Moves items that builds before June 2026 wrote to the file-based keychain
    /// into the data-protection keychain, once per install. A read of a legacy item
    /// can show the system's keychain-access prompt, so this never runs twice; an
    /// account that already has a data-protection item is not looked up at all.
    static func migrateLegacyItemsOnce(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: migrationFlag) else { return }
        // Set first: a crash mid-migration must not prompt again on every launch.
        defaults.set(true, forKey: migrationFlag)
        for key in accounts where read(key, dataProtection: true) == nil {
            guard let legacy = read(key, dataProtection: false) else { continue }
            set(legacy, key: key)
            var query = baseAttributes
            query[kSecAttrAccount as String] = key
            query[kSecUseDataProtectionKeychain as String] = false
            SecItemDelete(query as CFDictionary)
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
