import Foundation
import Security

/// Minimal Keychain wrapper for credentials — API key and OAuth tokens.
/// Secrets never go to UserDefaults, a plist, or a log line.
enum KeychainHelper {
    private static let service = "com.universe.apikeys"
    private static let legacyService = "com.tamaclone.apikeys"

    static func set(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        /* Device-only and not until first unlock: the secret never syncs to iCloud
           Keychain and is unreadable while the machine is locked at boot. */
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        if let value = read(service: service, account: account) { return value }
        /* The app was renamed from TamaClone; carry an existing key over once so
           the rename doesn't silently lose it. */
        if let legacy = read(service: legacyService, account: account) {
            set(legacy, account: account)
            return legacy
        }
        return nil
    }

    static func remove(account: String) {
        for service in [service, legacyService] {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ] as CFDictionary)
        }
    }

    private static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
