import Foundation
import Intents

// MARK: - One-time purge of interactions donated by earlier builds
//
// Earlier builds of the notification service extension donated an
// `INSendMessageIntent` whose `content` was the DECRYPTED chat message, which writes
// that text into the system Interactions store — outside the app container and
// outside the end-to-end-encryption boundary. Nothing ever purged it.
//
// Owner decision 2026-10-28 (follow-up 688E7D6E): decrypted chat text must not live
// outside the app container. The extension no longer donates (see
// `CommunicationIntentBuilder`); this clears what earlier builds already left behind.
//
// It runs from the MAIN APP, not the extension: an extension has a ~24 MB / 30 s
// budget and is gone before a purge could be trusted to finish. `deleteAll` is scoped
// to this app's own donations, and the app donates nothing else, so nothing of value
// is lost. A per-install flag makes it run once; the flag is only set after the
// system reports success, so a failed purge retries on the next launch.

nonisolated enum LegacyInteractionPurge {

    /// Bump the suffix only if a future build needs to purge again.
    static let flagKey = "privacy.legacyInteractionsPurged.v1"

    /// Runs the purge at most once per install (the flag lives in standard
    /// `UserDefaults`, which a delete-and-reinstall resets along with the store).
    /// `deleteAll` is injectable so the run-once guard is testable without a device.
    static func runOnce(
        defaults: UserDefaults = .standard,
        deleteAll: (@escaping @Sendable (Error?) -> Void) -> Void = { completion in
            INInteraction.deleteAll(completion: completion)
        }
    ) {
        guard !defaults.bool(forKey: flagKey) else { return }
        // The system calls back on its own queue. `UserDefaults` is documented
        // thread-safe but is not declared `Sendable` in the SDK.
        let box = DefaultsBox(defaults: defaults)
        deleteAll { error in
            if error == nil { box.defaults.set(true, forKey: flagKey) }
        }
    }

    private struct DefaultsBox: @unchecked Sendable {
        let defaults: UserDefaults
    }
}
