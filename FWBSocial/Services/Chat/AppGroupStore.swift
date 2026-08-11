import Foundation

// MARK: - App Group store
//
// Ported from Cove's `AppGroupStore` (168 LoC), pruned of the nudge / mutual-glow /
// favorites surfaces that die with the Commune product features (PLAN.md §8).
//
// Compiled into BOTH the app (the writer) and `FWBSocialNotificationService` (the
// reader) — an extension cannot import its host app. `nonisolated` so it is safe
// from the NSE's background context and from the app under default-MainActor
// isolation.
//
// What it carries and why:
//
//   • `hideMessagePreviews` — PLAN.md §4.3.5 is blunt about this: the flag is
//     enforced **client-side in the NSE**, because the server has ciphertext and
//     nothing to redact, and the NSE cannot read the Postgres column. "The flag must
//     be mirrored into the App Group on login and on every settings change. Without
//     that write path the column is inert and the setting silently does nothing."
//     Both write paths are wired: `ChatService.mirrorPreferences` on session restore
//     and `SettingsView`'s toggle.
//
//   • sender names / conversation titles / avatar JPEGs — so a banner can read
//     "Alex • Trip" with the sender's picture, resolved ON DEVICE. None of this ever
//     travels through APNs, which is the point: the payload is metadata only.

nonisolated enum AppGroupStore {

    /// Must match `com.apple.security.application-groups` on BOTH targets.
    static let suiteName = "group.events.fwb.social"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: suiteName) }

    // MARK: - Preview preference

    private static let hidePreviewsKey = "notif.hideMessagePreviews"

    /// Mirrors `fwb_users.hide_message_previews`. Default false — useful previews out
    /// of the box, still governed by iOS's own "show previews when unlocked".
    static var hideMessagePreviews: Bool {
        get { defaults?.bool(forKey: hidePreviewsKey) ?? false }
        set { defaults?.set(newValue, forKey: hidePreviewsKey) }
    }

    // MARK: - Identity cache

    private static let senderNamesKey = "cache.senderNames"
    private static let conversationTitlesKey = "cache.conversationTitles"

    static func displayName(forSenderId id: String) -> String? {
        (defaults?.dictionary(forKey: senderNamesKey) as? [String: String])?[id]
    }

    static func title(forConversationId id: String) -> String? {
        (defaults?.dictionary(forKey: conversationTitlesKey) as? [String: String])?[id]
    }

    /// Merge, never replace: the app learns names from several places (conversation
    /// members, friends, forum authors) and a wholesale write from one of them would
    /// drop what the others taught it.
    static func mergeSenderNames(_ names: [String: String]) {
        guard let defaults, !names.isEmpty else { return }
        var current = (defaults.dictionary(forKey: senderNamesKey) as? [String: String]) ?? [:]
        for (key, value) in names { current[key] = value }
        defaults.set(current, forKey: senderNamesKey)
    }

    static func mergeConversationTitles(_ titles: [String: String]) {
        guard let defaults, !titles.isEmpty else { return }
        var current = (defaults.dictionary(forKey: conversationTitlesKey) as? [String: String]) ?? [:]
        for (key, value) in titles { current[key] = value }
        defaults.set(current, forKey: conversationTitlesKey)
    }

    // MARK: - Avatar cache

    /// Avatars are FILES in the App Group container, not `UserDefaults` values —
    /// stuffing JPEGs into the prefs plist would bloat the file that every name
    /// lookup reads.
    private static let avatarsDirectoryName = "sender-avatars"

    private static var avatarsDirectory: URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: suiteName) else { return nil }
        let directory = container.appendingPathComponent(avatarsDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func avatarData(forSenderId id: String) -> Data? {
        guard let directory = avatarsDirectory else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent("\(id).jpg"))
    }

    /// Written `completeUntilFirstUserAuthentication` so a locked NSE can still read
    /// it after the first unlock. Avatars are not sensitive; this file protection
    /// exists for extension access, not secrecy.
    static func storeAvatar(_ jpeg: Data, forSenderId id: String) {
        guard let directory = avatarsDirectory else { return }
        try? jpeg.write(
            to: directory.appendingPathComponent("\(id).jpg"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    // MARK: - Sign-out

    /// Clear the mirrored identity cache so one account's contacts can't leak into
    /// the next member's notifications on a shared device.
    static func clear() {
        defaults?.removeObject(forKey: senderNamesKey)
        defaults?.removeObject(forKey: conversationTitlesKey)
        defaults?.removeObject(forKey: hidePreviewsKey)
        if let directory = avatarsDirectory {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
