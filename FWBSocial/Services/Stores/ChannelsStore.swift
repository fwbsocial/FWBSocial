import Foundation
import Observation

// MARK: - Channels store
//
// The Channels tab's data, promoted out of `ChannelsView`'s `@State` so it warms
// at launch and survives navigation. See `AnnouncementsStore` for the three
// properties every one of these stores has to have; this file only notes what is
// specific to channels.
//
// **Roles come from the server and are only ever drawn.** The list carries the
// caller's resolved role per channel (`mayPost`, `effective_role`); this store
// caches those answers, it never computes one. `ChannelAccess` re-decides on
// every request, so a stale cached role can make the app draw a composer that
// the server then refuses — which is the correct failure, and the reason the
// list refreshes on foreground rather than being trusted indefinitely.

@Observable
@MainActor
final class ChannelsStore {

    static let shared = ChannelsStore()

    private(set) var channels: [Channel] = []

    /// True once a load has completed — successfully, refused, or failed.
    private(set) var hasLoaded = false

    /// Kept unflattened so the view can distinguish an offline device from a
    /// server refusal, and so the server's own sentence survives to the screen.
    private(set) var loadError: Error?

    /// The server's own explanation for a 403.
    ///
    /// **Not an error.** `RequireVettedMember` distinguishes pending / banned /
    /// revoked / rejected and writes the right sentence for each, and the tab
    /// renders it as an explanation rather than a failure — telling a banned
    /// member to go check in at an event would be the alternative.
    private(set) var accessMessage: String?

    private var isRefreshing = false

    private init() {}

    /// The one spinner: before any data exists, and never again.
    private(set) var isInitialLoading = false

    /// Only where the SERVER's resolved role allows a thread to be started.
    var postableChannels: [Channel] { channels.filter { $0.mayPost && !$0.archived } }

    // MARK: - Loading

    /// Launch prefetch and tab entry. Does nothing once loaded.
    func warm() async {
        guard !hasLoaded else { return }
        await refresh()
    }

    /// Silent refresh: `channels` is replaced in one assignment once the new list
    /// lands, so a refresh over content never blanks the list, and a failure over
    /// content leaves the rows in place for `InlineErrorRow` to sit above.
    func refresh() async {
        // Signed out this route is a 401 and the tab is showing the members-only
        // prompt anyway. A pending member is NOT skipped: the 403 is how the tab
        // gets the server's sentence, and it is the whole content of the state
        // they see.
        // Never fetch while session restore is still in flight: "signed out" and
        // "not known yet" are different answers, and acting on the second is what
        // produced the Feed's empty-at-launch bug (see `AnnouncementsStore.warm`).
        guard AuthService.shared.didRestoreSession else { return }
        guard AuthService.shared.isSignedIn else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        if !hasLoaded { isInitialLoading = true }
        defer { isRefreshing = false; isInitialLoading = false; hasLoaded = true }

        do {
            channels = try await APIClient.shared.channels()
            loadError = nil
            accessMessage = nil
        } catch let APIError.httpError(code, message) where code == 403 {
            // Not vetted (or banned, or revoked) — an expected answer, not a
            // failure to report. The server's message says which.
            channels = []
            accessMessage = message
            loadError = nil
        } catch {
            // A cancelled refresh is not a failure worth showing; and a failure
            // must not discard channels that are already on screen.
            if !isCancellationError(error) { loadError = error }
        }
    }

    // MARK: - Session

    func handleSignOut() {
        channels = []
        loadError = nil
        accessMessage = nil
        hasLoaded = false
        isInitialLoading = false
    }
}
