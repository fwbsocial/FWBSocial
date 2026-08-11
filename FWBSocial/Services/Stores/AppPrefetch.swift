import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: "events.fwb.social", category: "Prefetch")

// MARK: - Launch prefetch
//
// **Owner directive 2026-08-11: a member never sees a tab load.** All four tabs'
// data warms at launch, so the first tap on any of them shows content — no
// spinner, no empty state that turns into rows a moment later.
//
// This is the one place that decides when the four stores fetch. It exists as a
// coordinator rather than as four `.task`s scattered through the shell because
// the ordering rules are shared and easy to get subtly wrong:
//
//  * **Parallel, not sequential.** Four `await`s in a row make the last tab's
//    content arrive after four round trips. These are independent routes on the
//    same host; they go out together.
//  * **Fire-and-forget.** The shell must render immediately. Nothing here is
//    awaited by a view's body.
//  * **After session restore.** `FWBSocialApp` awaits `restoreSession()` before
//    the shell's `.task` runs, so by the time this fires `AuthService` knows who
//    the member is and each store asks the right route for them.
//  * **Signed out still warms the feed.** Home renders signed out by design
//    (PLAN.md §4.1, Guideline 2.1), so its store has no auth guard. The
//    member-only stores skip cleanly — their tabs are showing a sign-in prompt.
//
// `ChatService` already behaved this way and is not re-plumbed: it is called
// from here so there is a single launch path, and `start()` is idempotent.

@MainActor
enum AppPrefetch {

    /// How stale content may get before returning to the app refreshes it.
    /// Deliberately coarse — every tab switch and every pull already refreshes,
    /// and a member who backgrounds and foregrounds the app twice in ten seconds
    /// should not send eight requests for it.
    private static let foregroundRefreshInterval: TimeInterval = 60

    private static var lastForegroundRefresh: Date?

    /// Warm every tab. Called at launch and whenever a session appears.
    ///
    /// Each store's `warm()` is a no-op once it holds data, so calling this more
    /// than once costs nothing — which is what lets the sign-in transition and
    /// the launch task share one entry point.
    static func warmAll() {
        logger.debug("warming all tabs")
        // Whatever the previous run of this app cached on disk belongs to
        // whoever was signed in then — see `FWBHTTP.clearSharedCache`.
        FWBHTTP.clearSharedCache()
        // Separate tasks, deliberately: a task group would still be one task from
        // the caller's point of view, and one slow route would hold the others'
        // results back from the screen. These publish independently, so whichever
        // tab the member taps first shows whatever has landed.
        Task { await ChatService.shared.start() }
        Task { await AnnouncementsStore.shared.warm() }
        Task { await ChannelsStore.shared.warm() }
        Task { await EventsStore.shared.warm() }
        Task { await BlockStore.shared.loadIfNeeded() }
    }

    /// Signing in.
    ///
    /// Not just `warmAll()`: the Home feed may already hold a page, because it
    /// is the one surface that renders signed out — and that page is the PUBLIC
    /// feed, a different list from the one this member is entitled to. `warm()`
    /// would see `hasLoaded` and do nothing, so the announcements store is asked
    /// to refresh outright while the other three, which have nothing yet, warm.
    static func signedIn() {
        logger.notice("signed in — rewarming every tab")
        FWBHTTP.clearSharedCache()
        Task { await AnnouncementsStore.shared.refresh() }
        Task { await ChatService.shared.start() }
        Task { await ChannelsStore.shared.warm() }
        Task { await EventsStore.shared.warm() }
        Task { await BlockStore.shared.loadIfNeeded() }
    }

    /// The vetting transition.
    ///
    /// A pending member's channels and events routes answer 403, and the two tabs
    /// draw the server's explanation. The moment vetting flips — which happens
    /// server-side, from a Luma check-in, while the app is open — those same
    /// routes start answering with content, and nothing else would ask again
    /// until the member happened to pull to refresh on a screen that is telling
    /// them to go and get vetted.
    ///
    /// The stores are cleared first rather than refreshed in place: `hasLoaded`
    /// is what suppresses their spinner, and this is the one moment where the
    /// previous answer ("you can't see this yet") must not be left on screen
    /// behind a silent refresh.
    static func vettingDidChange() {
        logger.notice("vetting changed — rewarming the gated tabs")
        ChannelsStore.shared.handleSignOut()
        EventsStore.shared.handleSignOut()
        Task { await ChannelsStore.shared.warm() }
        Task { await EventsStore.shared.warm() }
        // Chat's realtime seam and conversation list are behind the same gate.
        Task { await ChatService.shared.start() }
    }

    /// Returning to the foreground: refresh everything **silently**, throttled.
    ///
    /// Every store shows visible loading only before its first data, so this
    /// updates stale content underneath the member without anything moving that
    /// they did not cause.
    static func applicationDidBecomeActive() {
        if let last = lastForegroundRefresh,
           Date().timeIntervalSince(last) < foregroundRefreshInterval {
            logger.debug("foreground refresh throttled")
            return
        }
        lastForegroundRefresh = Date()
        logger.debug("foreground refresh")

        Task { await AnnouncementsStore.shared.refresh() }
        Task { await ChannelsStore.shared.refresh() }
        Task { await EventsStore.shared.refresh() }
        Task {
            guard AuthService.shared.isSignedIn else { return }
            await ChatService.shared.refreshConversations()
        }
    }

    /// Sign-out: every store drops the member's data, mirroring
    /// `ChatService.handleSignOut`.
    ///
    /// Home is warmed again straight afterwards because it is not a members-only
    /// surface — signing out leaves you on a working public feed, not on an empty
    /// screen, and the public feed is a different list from the one that was on
    /// screen a moment ago.
    static func handleSignOut() {
        // First, and before anything can refetch: a cached response keyed only by
        // URL would otherwise be handed to whoever signs in next (bug 8CC9EC4F).
        FWBHTTP.clearSharedCache()
        ChatService.shared.handleSignOut()
        AnnouncementsStore.shared.handleSignOut()
        ChannelsStore.shared.handleSignOut()
        EventsStore.shared.handleSignOut()
        BlockStore.shared.signedOut()
        lastForegroundRefresh = nil
        Task { await AnnouncementsStore.shared.warm() }
    }
}
