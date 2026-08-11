import Foundation

// MARK: - Announcements endpoints (PLAN.md §4.1)
//
//   GET    /api/public/announcements[/:id]   unauthenticated, visibility=public
//   GET    /api/announcements[/:id]          authenticated, adds vetted + read state
//   POST   /api/admin/announcements          admin create
//   PATCH  /api/admin/announcements/:id      admin edit
//   DELETE /api/admin/announcements/:id      admin delete
//   POST   /api/admin/announcements/:id/publish
//
// The **unauthenticated read is a shipping requirement, not a convenience**: a
// members-only app behind a hard login wall is the classic Guideline 2.1
// "unable to review" rejection. A signed-out Home tab gives a reviewer a working
// app in three seconds, for the cost of one route.
//
// `feed(...)` picks the route by auth state, and falls back to the public route
// if the authenticated one isn't there — so a partially deployed server still
// renders something rather than an error.

extension APIClient {

    /// One page of announcements, choosing the right route for the caller's
    /// auth state.
    func announcementsFeed(page: Int, per: Int) async throws -> PagedResponse<Announcement> {
        let query = ["page": "\(page)", "per": "\(per)"]
        if isAuthenticated {
            do {
                return try await get(APIClient.path("/api/announcements", query: query))
            } catch let APIError.httpError(code, _) where code == 404 {
                // Authenticated route not deployed yet — the public one still is.
                return try await get(APIClient.path("/api/public/announcements", query: query))
            }
        }
        return try await get(APIClient.path("/api/public/announcements", query: query))
    }

    /// A single announcement, by id. Used by the detail screen and by the push
    /// deep link, which can arrive before the feed has ever been loaded.
    func announcement(id: String) async throws -> Announcement {
        if isAuthenticated {
            do {
                return try await get("/api/announcements/\(id)")
            } catch let APIError.httpError(code, _) where code == 404 {
                return try await get("/api/public/announcements/\(id)")
            }
        }
        return try await get("/api/public/announcements/\(id)")
    }

    // MARK: - Admin
    //
    // Gated in the UI by `AuthUser.isAdmin`, and gated for real by the server's
    // `RequireAdmin` middleware. The client check decides what to draw; it never
    // decides what is allowed.

    @discardableResult
    func createAnnouncement(_ draft: AnnouncementDraft) async throws -> Announcement {
        try await post("/api/admin/announcements", body: draft)
    }

    @discardableResult
    func updateAnnouncement(id: String, _ draft: AnnouncementDraft) async throws -> Announcement {
        try await patch("/api/admin/announcements/\(id)", body: draft)
    }

    func deleteAnnouncement(id: String) async throws {
        try await delete("/api/admin/announcements/\(id)")
    }

    /// Publish. The server records `push_sent_at` so a second publish can't
    /// double-push the membership.
    @discardableResult
    func publishAnnouncement(id: String) async throws -> Announcement {
        try await post("/api/admin/announcements/\(id)/publish")
    }
}
