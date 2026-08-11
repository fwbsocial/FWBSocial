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

    func loadNext(_ fetch: PageFetcher) async {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        error = nil
        failure = nil
        do {
            let response = try await fetch(page, per)
            items.append(contentsOf: response.items)
            total = response.metadata?.total

            // `has_more` is the server saying so, which beats every inference —
            // fwb-server's feed envelope carries it (AnnouncementDTOs.swift).
            // The short-page and total heuristics stay as the fallback for
            // routes that don't.
            if let hasMore = response.hasMore {
                reachedEnd = !hasMore
                if hasMore { page += 1 }
            } else {
                if response.items.count < per { reachedEnd = true } else { page += 1 }
                if let total, items.count >= total { reachedEnd = true }
            }
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
        hasLoaded = true
    }

    /// Call from a row `.onAppear` to trigger the next page near the end.
    func loadMoreIfNeeded(current item: Item, _ fetch: PageFetcher) async {
        guard let last = items.last, last.id == item.id else { return }
        await loadNext(fetch)
    }

    /// Replace a loaded item in place (matched by `id`).
    func replace(_ item: Item) {
        if let idx = items.firstIndex(where: { $0.id == item.id }) { items[idx] = item }
    }
}
