import Foundation
import OSLog
import Security

private nonisolated let logger = Logger(subsystem: "events.fwb.social", category: "ChatKeychain")

/// Keychain storage for chat key material — ported from Cove's `EncryptionService.Keychain`
/// with one substantive change: **every item is written into the shared access group.**
///
/// # Why the access group is written, not inherited
///
/// House gotcha `reference_commune_nse_keychain_no_migration`: keychain items do
/// **not** migrate into an extension's access group. An item the app saved into its
/// own default group is invisible to `FWBSocialNotificationService`, and the failure
/// is silent — every chat notification degrades to a contentless "New message"
/// banner with nothing in the log to say why (PLAN.md R5).
///
/// So `save` sets `kSecAttrAccessGroup` explicitly. Reads are deliberately
/// **groupless**: a groupless `SecItemCopyMatching` searches every group the calling
/// process is entitled to, which finds shared-group items from either process *and*
/// still finds anything an older build wrote into the app's default group.
///
/// # Accessibility, and why it is `AfterFirstUnlock`
///
/// PLAN.md §4.3.3(B) records Cove's two-tier split. This store is the NSE-readable
/// tier: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. An item stored
/// `WhenUnlocked…` is unavailable while the phone is locked, which would make
/// lock-screen previews impossible by construction. The Secure Enclave identity and
/// signing keys are a separate, stricter tier — they are created with
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` access control in
/// `ChatEncryptionService`, and the NSE never touches them (it is quantum-only).
///
/// `ThisDeviceOnly` on every item excludes them from iCloud Keychain, from encrypted
/// backups, **and from device-to-device migration** — which is exactly why a new
/// phone is a new device that must be approved, and why PLAN-ADDENDUM A2's history
/// handoff exists.
nonisolated enum ChatKeychain {

    /// Must match the `keychain-access-groups` entitlement on BOTH targets.
    /// `AppIdentifierPrefix` is resolved at runtime from the app's own entitlements
    /// rather than hardcoded, because the team prefix differs between the free team
    /// and `NVT8G575R7` and a hardcoded prefix fails in a way that looks like data
    /// loss.
    static let accessGroup: String? = resolveAccessGroup()

    /// Namespaced so these can never collide with — or be matched by — the auth
    /// tokens or any other generic-password item.
    private static let service = "events.fwb.social.chatkeys"

    // MARK: - Save

    /// Atomic write: update in place, or add. The delete-then-add pattern Cove
    /// started with had a window where a crash between the two lost the item
    /// permanently — and for the identity key that is all decryptable history.
    static func save(_ data: Data, forKey key: String) throws {
        var match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup { match[kSecAttrAccessGroup as String] = accessGroup }

        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(match as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw ChatKeychainError.saveFailed(updateStatus) }

        var addQuery = match
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess { return }

        // -34018 `errSecMissingEntitlement`: the Keychain Sharing capability is not
        // on this build's provisioning profile. Rather than lose the key entirely,
        // fall back to the app's default group and say so — the app keeps working,
        // the NSE does not, and the log names the reason instead of leaving a
        // contentless banner as the only symptom.
        if addStatus == errSecMissingEntitlement, accessGroup != nil {
            logger.error("Keychain access group refused (errSecMissingEntitlement) — writing ungrouped. NSE decryption will not work on this build.")
            var ungrouped = addQuery
            ungrouped.removeValue(forKey: kSecAttrAccessGroup as String)
            let retry = SecItemAdd(ungrouped as CFDictionary, nil)
            guard retry == errSecSuccess else { throw ChatKeychainError.saveFailed(retry) }
            return
        }
        throw ChatKeychainError.saveFailed(addStatus)
    }

    // MARK: - Load / delete

    /// Groupless read — searches every entitled group, so it finds shared-group
    /// items from either process and legacy ungrouped items from an older build.
    static func load(forKey key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Access-group resolution

    /// Resolve `$(AppIdentifierPrefix)events.fwb.social` at runtime.
    ///
    /// The team prefix cannot be hardcoded — it differs between the free team and
    /// `NVT8G575R7`, and a wrong prefix fails in a way that looks exactly like data
    /// loss. `SecTaskCopyValueForEntitlement` would answer this directly but is
    /// macOS-only; on iOS the portable trick is to add a throwaway item with NO
    /// access group, read back the group the system assigned it — which is always
    /// `<TeamPrefix>.<default group>` — and take the prefix from that.
    private static func resolveAccessGroup() -> String? {
        let probeAccount = "fwb.chat.accessgroup.probe"
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: probeAccount,
        ]
        SecItemDelete(base as CFDictionary)

        var add = base
        add[kSecValueData as String] = Data([0])
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecReturnAttributes as String] = true
        var result: AnyObject?
        let status = SecItemAdd(add as CFDictionary, &result)
        defer { SecItemDelete(base as CFDictionary) }

        guard status == errSecSuccess,
              let attributes = result as? [String: Any],
              let assigned = attributes[kSecAttrAccessGroup as String] as? String,
              let separator = assigned.firstIndex(of: ".")
        else {
            logger.notice("Could not resolve a keychain access group; falling back to the default group.")
            return nil
        }
        let prefix = assigned[assigned.startIndex ..< separator]
        return "\(prefix).events.fwb.social"
    }
}

nonisolated enum ChatKeychainError: LocalizedError {
    case saveFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status): return "Keychain save failed (OSStatus \(status))."
        }
    }
}
