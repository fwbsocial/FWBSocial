import SwiftUI
import Observation

/// A reusable pagination loader over a `PagedResponse<T>` endpoint. Ported
/// verbatim from Flux's `Components/PaginatedList.swift` (PLAN.md §5.2) — no
/// Flux-specific logic to strip.
///
/// ```
/// @State private var loader = PaginatedLoader<Announcement>()
/// // ...
/// .task { await loader.loadFirst { page, per in
///     try await APIClient.shared.get(APIClient.path("/api/announcements",
///         query: ["page": "\(page)", "per": "\(per)"])) } }
/// ```
@Observable
@MainActor
final class PaginatedLoader<Item: Decodable & Sendable & Identifiable> {

    private(set) var items: [Item] = []
    private(set) var isLoading = false
    private(set) var reachedEnd = false
    private(set) var total: Int?
    var error: String?

    /// True only while an ADDITIONAL page is being appended below content that is
    /// already on screen.
    ///
    /// `isLoading` covers first loads and silent refreshes too, so a surface that
    /// draws its footer spinner from it flashes one over the member's content on
    /// every background refresh — the exact thing the house prefetch rule
    /// forbids. This is the flag a footer spinner wants.
    private(set) var isLoadingMore = false

    /// The same failure, unflattened.
    ///
    /// Phase 8: `error` (a `String`) is what most call sites want to print, but a
    /// string cannot answer "was this the network?", so no surface built on this
    /// loader could offer an offline branch. Both are kept in step; new code
    /// should read this one.
    private(set) var failure: Error?

    /// True once a load has completed — successfully or not.
    ///
    /// Distinguishes "the server said there is nothing" from "nothing has been
    /// asked yet", which is the difference between showing an empty state and
    /// showing a spinner.
    private(set) var hasLoaded = false

    private var page = 1
    private let per: Int

    init(per: Int = 20) { self.per = per }

    /// A closure that fetches one page (1-indexed).
    typealias PageFetcher = @Sendable (_ page: Int, _ per: Int) async throws -> PagedResponse<Item>

    func loadFirst(_ fetch: PageFetcher) async {
        page = 1
        reachedEnd = false
        items = []
        await loadNext(fetch)
    }

    /// Reload page one **without emptying the list first.**
    ///
    /// `loadFirst` clears `items` before it asks, which is right for a screen that
    /// is changing what it shows and wrong for one that is merely catching up:
    /// the member watches their content vanish, a spinner appear, and the same
    /// content come back. A store that refreshes at launch, on foreground and on
    /// every tab entry (the house prefetch rule) does that several times a
    /// session, so the silent path is the one it uses — the list is replaced in a
    /// single assignment once the new page has actually arrived.
    ///
    /// A failure leaves the existing items alone, which is what lets a surface
    /// draw `InlineErrorRow` over real content instead of a takeover error state.
    func refreshFirst(_ fetch: PageFetcher) async {
        guard !isLoading else { return }
        isLoading = true
        isLoadingMore = false
        error = nil
        failure = nil
        do {
            let response = try await fetch(1, per)
            items = response.items
            total = response.metadata?.total
            page = 1
            applyPaging(response)
        } catch {
            if !isCancellationError(error) {
                self.error = error.fwbMessage
                self.failure = error
            }
        }
        isLoading = false
        hasLoaded = true
    }

    func loadNext(_ fetch: PageFetcher) async {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        // Appending only when something is already on screen — the first page of
        // an empty list is a first load, not a "load more".
        isLoadingMore = !items.isEmpty
        error = nil
        failure = nil
        do {
            let response = try await fetch(page, per)
            items.append(contentsOf: response.items)
            total = response.metadata?.total
            applyPaging(response)
        } catch {
            // A cancelled load is not a failure. Navigating away mid-fetch tore the
            // task down and the view came back showing "cancelled" as if the server
            // had said it — every other loader in the app already guards this.
            if !isCancellationError(error) {
                self.error = error.fwbMessage
                self.failure = error
            }
        }
        isLoading = false
        isLoadingMore = false
        hasLoaded = true
    }

    /// Where the cursor lands after a page arrives.
    ///
    /// `has_more` is the server saying so, which beats every inference —
    /// fwb-server's feed envelope carries it (AnnouncementDTOs.swift). The
    /// short-page and total heuristics stay as the fallback for routes that
    /// don't.
    private func applyPaging(_ response: PagedResponse<Item>) {
        if let hasMore = response.hasMore {
            reachedEnd = !hasMore
            if hasMore { page += 1 }
        } else {
            if response.items.count < per { reachedEnd = true } else { page += 1 }
            if let total, items.count >= total { reachedEnd = true }
        }
    }

    /// Call from a row `.onAppear` to trigger the next page near the end.
    func loadMoreIfNeeded(current item: Item, _ fetch: PageFetcher) async {
        guard let last = items.last, last.id == item.id else { return }
        await loadNext(fetch)
    }

    /// Drop everything, back to the state a freshly built loader is in.
    ///
    /// For a shared loader whose audience changed under it — sign-out being the
    /// case that matters, where the next page belongs to a different reader
    /// entirely and showing the previous one's rows for even one frame would be
    /// a leak.
    func reset() {
        items = []
        page = 1
        reachedEnd = false
        total = nil
        error = nil
        failure = nil
        hasLoaded = false
        isLoadingMore = false
    }

    /// Replace a loaded item in place (matched by `id`).
    func replace(_ item: Item) {
        if let idx = items.firstIndex(where: { $0.id == item.id }) { items[idx] = item }
    }
}
