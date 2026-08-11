import Foundation
import Observation

// MARK: - Events store
//
// The Events tab's data — the caller's open friending windows and their Luma
// email status — promoted out of `EventsView`'s `@State` so it warms at launch
// and survives navigation. See `AnnouncementsStore` for the shape.
//
// **The countdown is the server's, and this store does not age it.**
// `secondsRemaining` is computed on the server's clock precisely because the
// device's can be wrong, so the value here is only as fresh as the last fetch —
// which is why the foreground refresh matters more on this tab than anywhere
// else: a phone that was in a pocket for six hours would otherwise draw a
// six-hour-stale deadline on a 48-hour window.

@Observable
@MainActor
final class EventsStore {

    static let shared = EventsStore()

    private(set) var windows: [FriendingWindowDTO] = []
    private(set) var lumaStatus: LumaEmailStatusDTO?

    /// True once a load has completed — successfully or not.
    private(set) var hasLoaded = false

    /// The one spinner: before any data exists, and never again.
    private(set) var isInitialLoading = false

    /// Unflattened, so the offline branch and the server's own refusal message
    /// both survive as far as the view. The vetting refusal is the single most
    /// likely failure on this screen and the server writes a good sentence for
    /// it — see `ErrorStateView`.
    private(set) var loadError: Error?

    private var isRefreshing = false

    private init() {}

    // MARK: - Loading

    func warm() async {
        guard !hasLoaded else { return }
        await refresh()
    }

    func refresh() async {
        // Never fetch while session restore is still in flight: "signed out" and
        // "not known yet" are different answers, and acting on the second is what
        // produced the Feed's empty-at-launch bug (see `AnnouncementsStore.warm`).
        guard AuthService.shared.didRestoreSession else { return }
        guard AuthService.shared.isSignedIn else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        if !hasLoaded { isInitialLoading = true }
        defer { isRefreshing = false; isInitialLoading = false; hasLoaded = true }

        // The Luma status is genuinely optional — it only decides whether an
        // explanatory card appears — so its failure stays swallowed. The windows
        // are the screen, so theirs does not.
        //
        // It must not be `try?` on BOTH: that destroys the `APIError` before
        // anything can read it, and a 403 "you aren't vetted yet" and a DNS
        // failure come out as the same sentence.
        async let statusTask = try? await EventsAPI.lumaEmailStatus()
        async let windowsTask = EventsAPI.openWindows()

        // A failed status must not blank a good one from the previous load.
        if let status = await statusTask { lumaStatus = status }
        do {
            windows = try await windowsTask
            loadError = nil
        } catch {
            if !isCancellationError(error) { loadError = error }
        }
    }

    // MARK: - Session

    func handleSignOut() {
        windows = []
        lumaStatus = nil
        loadError = nil
        hasLoaded = false
        isInitialLoading = false
    }
}
