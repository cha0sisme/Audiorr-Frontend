import Foundation
import Security

/// Keychain-backed store for Navidrome credentials.
/// Single source of truth for all native SwiftUI views — no JS bridge dependency.
final class CredentialsStore {

    static let shared = CredentialsStore()
    private init() {}

    private let service = "com.audiorr.navidrome"
    private let account = "credentials"

    // MARK: - Public API

    func load() -> NavidromeCredentials? {
        // 1. Try Keychain first (primary store)
        if let data = keychainRead(),
           let creds = try? JSONDecoder().decode(NavidromeCredentials.self, from: data) {
            return creds
        }
        // 2. Migration: if AppDelegate JS bridge previously stored creds in UserDefaults,
        //    adopt them into Keychain so future reads don't need the bridge.
        return migrateFromUserDefaults()
    }

    func save(_ creds: NavidromeCredentials) {
        guard let data = try? JSONEncoder().encode(creds) else { return }
        keychainWrite(data)
        // Mirror to UserDefaults so AppDelegate bridge + Capacitor still see the config
        if let json = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(json, forKey: "navidromeConfig")
        }
    }

    func delete() {
        keychainDelete()
        UserDefaults.standard.removeObject(forKey: "navidromeConfig")
    }

    // MARK: - Keychain helpers

    private func keychainRead() -> Data? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private func keychainWrite(_ data: Data) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attrs: [CFString: Any] = [kSecValueData: data]
        if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    private func keychainDelete() {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - UserDefaults migration (one-time)

    private func migrateFromUserDefaults() -> NavidromeCredentials? {
        guard let raw  = UserDefaults.standard.string(forKey: "navidromeConfig"),
              let data = raw.data(using: .utf8),
              let creds = try? JSONDecoder().decode(NavidromeCredentials.self, from: data)
        else { return nil }
        // Promote to Keychain
        keychainWrite(data)
        return creds
    }
}
