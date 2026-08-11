import Foundation
import Observation

// MARK: - Reporting and blocking
//
// Verified against the deployed fwb-server (plan §4.7, Guideline 1.2):
//
//   POST   /api/reports                  any authenticated member (rate-limited 20/5min)
//   GET    /api/reports/mine
//   GET    /api/blocks
//   POST   /api/blocks/:userId
//   DELETE /api/blocks/:userId
//   GET    /api/admin/reports            moderator tier
//   POST   /api/admin/reports/:id/assign | /resolve
//
// **These are NOT behind `RequireVettedMember`** — only `authenticated`. That is
// deliberate on the server and matters here: a member whose vetting was revoked
// for abuse must still be able to report and block. Never gate these affordances
// on `isVetted` client-side.

extension APIClient {

    // MARK: - Reports

    @discardableResult
    func report(
        targetType: ReportTargetType,
        targetId: String,
        reason: ReportReason,
        details: String?
    ) async throws -> ReportResponse {
        let trimmed = details?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await post("/api/reports", body: CreateReportRequest(
            targetType: targetType.rawValue,
            targetId: targetId,
            reason: reason.rawValue,
            details: (trimmed?.isEmpty == false) ? trimmed : nil))
    }

    func myReports() async throws -> [ReportResponse] {
        try await get("/api/reports/mine")
    }

    // MARK: - Blocks

    func blockedUsers() async throws -> [BlockedUserResponse] {
        try await get("/api/blocks")
    }

    /// Idempotent server-side — blocking someone already blocked succeeds rather
    /// than erroring, so the button never looks broken.
    func block(userId: String) async throws {
        let _: EmptyResponse = try await request("POST", "/api/blocks/\(userId)")
    }

    /// Unblocking does **not** restore what the block tore down: a severed
    /// friendship stays severed. The confirmation copy says so.
    func unblock(userId: String) async throws {
        try await delete("/api/blocks/\(userId)")
    }

    // MARK: - Admin / moderator triage

    /// `status` nil = the default working view (open + triaging), oldest first.
    func reportQueue(status: String? = nil, targetType: String? = nil) async throws -> ReportQueueResponse {
        try await get(APIClient.path("/api/admin/reports",
                                     query: ["status": status, "target_type": targetType]))
    }

    @discardableResult
    func assignReport(id: String, to assigneeId: String?) async throws -> ReportResponse {
        try await post("/api/admin/reports/\(id)/assign",
                       body: AssignReportRequest(assigneeId: assigneeId))
    }

    @discardableResult
    func resolveReport(id: String, outcome: ModerationOutcome, note: String?) async throws -> ReportResponse {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await post("/api/admin/reports/\(id)/resolve", body: ResolveReportRequest(
            resolution: outcome.rawValue,
            note: (trimmed?.isEmpty == false) ? trimmed : nil,
            status: outcome.reportStatus))
    }
}

// MARK: - Blocked-author filtering
//
// **The forum does not filter blocked authors server-side.** Confirmed by reading
// the module: `Modules/Forum/` references `BlockedTerms` (the word filter) and
// nothing else — there is no `BlockedUser` join on the post or comment queries.
// `BlockController.blockedIdsEitherWay` exists and is documented as being for
// "feeds", but Phase 4's feed does not call it.
//
// So the filtering is this client's job, and it has to be, or blocking someone
// would visibly do nothing on the surface where you most likely met them.
//
// Kept as one small shared store rather than per-view state: every UGC surface
// needs the same set, and re-fetching it per screen would both hammer the route
// and let two screens disagree about who is blocked.
@Observable
@MainActor
final class BlockStore {

    static let shared = BlockStore()

    /// Ids blocked by *this* member. The server's own predicate is symmetric
    /// (either direction hides content), but `GET /api/blocks` returns only the
    /// caller's own blocks — the other direction is invisible here by design, and
    /// asking for it would be a block-detection oracle.
    private(set) var blockedIds: Set<String> = []
    private(set) var hasLoaded = false

    private init() {}

    func refresh() async {
        guard APIClient.shared.isAuthenticated else {
            blockedIds = []
            hasLoaded = false
            return
        }
        do {
            let list = try await APIClient.shared.blockedUsers()
            blockedIds = Set(list.map(\.userId))
            hasLoaded = true
        } catch {
            // A failed refresh must not clear the set: showing content from
            // someone the member blocked is worse than a stale list.
        }
    }

    /// Load once per session unless something changed it.
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await refresh()
    }

    func isBlocked(_ userId: String?) -> Bool {
        guard let userId else { return false }
        return blockedIds.contains(userId)
    }

    /// Optimistic local insert so the feed updates the instant the sheet closes,
    /// before the round trip lands.
    func markBlocked(_ userId: String) {
        blockedIds.insert(userId)
    }

    func markUnblocked(_ userId: String) {
        blockedIds.remove(userId)
    }

    func signedOut() {
        blockedIds = []
        hasLoaded = false
    }
}

extension Array where Element == ForumPost {
    /// Drops posts by blocked authors. Applied at render time rather than at
    /// fetch time so an unblock brings content back without a refetch.
    func filteringBlocked(_ store: BlockStore) -> [ForumPost] {
        filter { !store.isBlocked($0.author?.id) }
    }
}

extension Array where Element == ForumComment {
    func filteringBlocked(_ store: BlockStore) -> [ForumComment] {
        filter { !store.isBlocked($0.author?.id) }
    }
}
