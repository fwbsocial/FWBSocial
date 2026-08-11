import Foundation
import Observation

// MARK: - Announcements store (Home tab)
//
// **The house prefetch rule (owner directive 2026-08-11): a member never sees a
// tab load.** All four tabs warm at launch and the first tap shows content.
// `ChatService` has worked this way since the tab-entry flash was reported; this
// is the same shape for the Home tab, and `ChannelsStore` / `EventsStore` are its
// two siblings.
//
// Three properties are what make that true, and they are the same three in all
// three stores:
//
//  1. **The data outlives the view.** It was view-local `@State` here, so
//     nothing existed until the first visit and navigating away and back
//     refetched from scratch.
//  2. **Visible loading only before the first data.** Every later refresh —
//     launch, foreground, tab entry, pull — happens behind what is already on
//     screen. `hasLoaded` is the gate, exactly as `hasLoadedConversations` is in
//     `ChatService`.
//  3. **The failure survives unflattened.** `Error`, not `String`, so the feed
//     keeps its offline branch and the server's own sentence (`ErrorStateView`).
//
// Pagination is deliberately NOT reimplemented: the store owns the same
// `PaginatedLoader` the view used to hold, so page two onwards is byte-for-byte
// the behaviour that already shipped. Only *where the loader lives* changed.

@Observable
@MainActor
final class AnnouncementsStore {

    static let shared = AnnouncementsStore()

    /// The pagination engine, unchanged and now shared. `AnnouncementsFeedView`
    /// reads it instead of holding one of its own.
    let loader = PaginatedLoader<Announcement>(per: 20)

    /// True once a first load has completed this session — successfully or not.
    /// Until it flips the feed shows one spinner; after it, refreshes are silent.
    private(set) var hasLoaded = false

    /// Announcements this session has opened, so the unread dot clears the moment
    /// the detail screen appears rather than at the next refresh.
    ///
    /// Kept as a set beside the rows rather than folded into them because
    /// `Announcement` is an immutable wire model — rebuilding one to flip a
    /// single flag would mean this client inventing a row the server never sent.
    private(set) var readIds: Set<String> = []

    /// Which feed the loaded page came from. The admin list is the only one that
    /// carries drafts, so a member who signs in as an admin (or an admin who
    /// signs out) must not keep looking at the other audience's page.
    private var loadedIncludingDrafts = false

    /// Single-flight. Launch prefetch, the view's `.task` and a foreground
    /// refresh can all land in the same runloop turn.
    private var isRefreshing = false

    private init() {}

    // MARK: - Reading

    var items: [Announcement] { loader.items }

    /// The last load's failure, unflattened — `ErrorStateView` classifies offline
    /// from it and `InlineErrorRow` prints the server's sentence.
    var failure: Error? { loader.failure }

    /// The one spinner: before any data exists, and never again.
    var isInitialLoading: Bool { !hasLoaded && loader.isLoading }

    /// Whether to draw the unread dot, taking this session's local reads into
    /// account. `isRead` is nil signed out, where unread means nothing.
    func isUnread(_ announcement: Announcement) -> Bool {
        announcement.isUnread && !readIds.contains(announcement.id)
    }

    // MARK: - Loading

    /// Launch prefetch. Does nothing once there is data — a second warm is a
    /// refresh's job, not this one's.
    ///
    /// **No auth guard.** The Home feed renders signed out (PLAN.md §4.1) and
    /// `APIClient.announcementsFeed` picks the public route when there's no
    /// session, so this is the one store that warms for a signed-out visitor too.
    func warm() async {
        guard !hasLoaded else { return }
        await refresh()
    }

    /// Silent refresh. Content on screen stays there until the new page arrives,
    /// and a failure leaves it alone — see `PaginatedLoader.refreshFirst`.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false; hasLoaded = true }

        // Admins read the admin list, which is the only feed that includes
        // drafts; everyone else reads the member or public feed.
        let includeDrafts = AuthService.shared.isAdmin
        loadedIncludingDrafts = includeDrafts
        await loader.refreshFirst(Self.fetcher(includeDrafts: includeDrafts))
    }

    /// Page two onwards, from the feed's last row. Straight through to the
    /// loader that already implemented it.
    func loadMoreIfNeeded(current announcement: Announcement) async {
        await loader.loadMoreIfNeeded(
            current: announcement,
            Self.fetcher(includeDrafts: loadedIncludingDrafts))
    }

    private static func fetcher(includeDrafts: Bool) -> PaginatedLoader<Announcement>.PageFetcher {
        { page, per in
            try await APIClient.shared.announcementsFeed(
                page: page, per: per, includeDrafts: includeDrafts)
        }
    }

    // MARK: - Read state

    /// Mark an announcement read: locally first so the dot clears immediately,
    /// then on the server. Fire-and-forget by nature — failing to record a read
    /// is not worth interrupting anyone over.
    func markRead(id: String) async {
        readIds.insert(id)
        await APIClient.shared.markAnnouncementRead(id: id)
    }

    // MARK: - Session

    /// Sign-out. Mirrors `ChatService.handleSignOut` — the member's feed and read
    /// state leave with the session, and the next warm fetches the public feed.
    func handleSignOut() {
        loader.reset()
        readIds = []
        hasLoaded = false
        loadedIncludingDrafts = false
    }
}
