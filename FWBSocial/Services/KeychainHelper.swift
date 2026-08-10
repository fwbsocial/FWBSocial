import Foundation
import Security
import OSLog

// Explicitly nonisolated: under default-MainActor isolation this global would be
// MainActor-isolated, which the nonisolated keychain methods can't reference.
private nonisolated let logger = Logger(subsystem: "events.fwb.social", category: "Keychain")

/// App-scoped Keychain helper for token storage. Ported verbatim from Flux's
/// `KeychainHelper` — no Flux-specific logic to strip.
enum KeychainHelper {

    /// Default service for FWB Social auth tokens.
    static let authService = "events.fwb.social.auth"

    nonisolated static func save(key: String, value: String, service: String) {
        guard let data = value.data(using: .utf8) else {
            logger.error("Keychain save failed: cannot encode value for key '\(key)'")
            return
        }
        delete(key: key, service: service)
        let query: [String: Any] = [
            kSecClass as String:          kSecClassGenericPassword,
            kSecAttrService as String:    service,
            kSecAttrAccount as String:    key,
            kSecValueData as String:      data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("Keychain save failed for key '\(key)': OSStatus \(status)")
        }
    }

    nonisolated static func load(key: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
                return nil
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            logger.error("Keychain load failed for key '\(key)': OSStatus \(status)")
            return nil
        }
    }

    nonisolated static func delete(key: String, service: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
