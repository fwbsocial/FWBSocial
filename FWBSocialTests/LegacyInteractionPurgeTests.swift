import Testing
import Foundation
@testable import FWBSocial

// MARK: - One-time Interactions purge (follow-up 688E7D6E)
//
// `INInteraction.deleteAll` itself needs a real device; what is testable is the
// run-once guard around it, with the deleter injected.

@Suite("Legacy interaction purge")
struct LegacyInteractionPurgeTests {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        func bump() { lock.lock(); value += 1; lock.unlock() }
    }

    /// A throwaway suite so the real standard defaults are never touched.
    private static func freshDefaults() throws -> UserDefaults {
        let name = "LegacyInteractionPurgeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("A successful purge runs once, then never again")
    func runsOnceOnSuccess() throws {
        let defaults = try Self.freshDefaults()
        let calls = Counter()
        let deleteAll: (@escaping @Sendable (Error?) -> Void) -> Void = { completion in
            calls.bump()
            completion(nil)
        }

        LegacyInteractionPurge.runOnce(defaults: defaults, deleteAll: deleteAll)
        LegacyInteractionPurge.runOnce(defaults: defaults, deleteAll: deleteAll)
        LegacyInteractionPurge.runOnce(defaults: defaults, deleteAll: deleteAll)

        #expect(calls.count == 1)
        #expect(defaults.bool(forKey: LegacyInteractionPurge.flagKey))
    }

    @Test("A failed purge leaves the flag unset so the next launch retries")
    func retriesAfterFailure() throws {
        let defaults = try Self.freshDefaults()
        let calls = Counter()
        struct PurgeFailed: Error {}

        LegacyInteractionPurge.runOnce(defaults: defaults) { completion in
            calls.bump()
            completion(PurgeFailed())
        }
        #expect(!defaults.bool(forKey: LegacyInteractionPurge.flagKey))

        LegacyInteractionPurge.runOnce(defaults: defaults) { completion in
            calls.bump()
            completion(nil)
        }
        #expect(calls.count == 2)
        #expect(defaults.bool(forKey: LegacyInteractionPurge.flagKey))
    }

    @Test("An already-flagged install never calls the system")
    func flaggedInstallSkips() throws {
        let defaults = try Self.freshDefaults()
        defaults.set(true, forKey: LegacyInteractionPurge.flagKey)
        let calls = Counter()

        LegacyInteractionPurge.runOnce(defaults: defaults) { completion in
            calls.bump()
            completion(nil)
        }

        #expect(calls.count == 0)
    }
}
