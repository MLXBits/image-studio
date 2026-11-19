import Foundation
import Security

enum KeychainHelper {
    /// The outcome of one keychain read.
    private enum Lookup {
        case found(String)
        /// No item, or an item with no usable value.
        case missing
        /// The user cancelled the access prompt, or authorization failed.
        case denied
        /// Any other error; worth trying again later.
        case failed
    }

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
    /// been settled and is never looked up again; an account that already has a
    /// data-protection item is not looked up at all.
    ///
    /// Settled means: copied (the legacy item is deleted only after the copy
    /// saves), no legacy item, or the user declined the prompt. Any other read or
    /// write error, such as a locked keychain, leaves the account unmarked so the
    /// next launch tries again.
    static func migrateLegacyItemsOnce(defaults: UserDefaults = .standard) {
        for key in accounts where !defaults.bool(forKey: migrationFlagPrefix + key) {
            if migrateLegacyItem(key) {
                defaults.set(true, forKey: migrationFlagPrefix + key)
            }
        }
    }

    /// One account's migration. Returns whether the account is settled.
    private static func migrateLegacyItem(_ key: String) -> Bool {
        switch lookup(key, dataProtection: true) {
        case .found: return true
        case .missing: break
        case .denied, .failed: return false
        }
        switch lookup(key, dataProtection: false) {
        case let .found(legacy):
            guard set(legacy, key: key) == errSecSuccess else { return false }
            var query = baseAttributes
            query[kSecAttrAccount as String] = key
            query[kSecUseDataProtectionKeychain as String] = false
            SecItemDelete(query as CFDictionary)
            return true
        case .missing, .denied:
            return true
        case .failed:
            return false
        }
    }

    private static func read(_ key: String, dataProtection: Bool) -> String? {
        if case let .found(value) = lookup(key, dataProtection: dataProtection) {
            return value
        }
        return nil
    }

    private static func lookup(_ key: String, dataProtection: Bool) -> Lookup {
        var query = baseAttributes
        query[kSecAttrAccount as String] = key
        query[kSecUseDataProtectionKeychain as String] = dataProtection
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8),
                  !value.isEmpty else { return .missing }
            return .found(value)
        case errSecItemNotFound:
            return .missing
        case errSecUserCanceled, errSecAuthFailed:
            return .denied
        default:
            return .failed
        }
    }
}
