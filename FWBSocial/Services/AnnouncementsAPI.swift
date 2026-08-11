import Foundation

// MARK: - Announcements endpoints
//
// Verified against the deployed fwb-server (PLAN.md §4.1):
//
//   GET    /api/public/announcements[/:id]      unauthenticated, visibility=public
//   GET    /api/announcements[/:id]             authenticated, adds vetted + read state
//   POST   /api/announcements/:id/read          mark read
//   GET    /api/admin/announcements             admin list (includes drafts)
//   POST   /api/admin/announcements             admin create
//   PATCH  /api/admin/announcements/:id         admin edit
//   DELETE /api/admin/announcements/:id         admin delete
//   POST   /api/admin/announcements/:id/publish | unpublish
//   GET|PUT /api/me/notifications               notification preferences
//
// The **unauthenticated read is a shipping requirement, not a convenience**: a
// members-only app behind a hard login wall is the classic Guideline 2.1
// "unable to review" rejection. `feed(...)` picks the route by auth state and
// falls back to the public one if the authenticated route is missing, so a
// partially deployed server still renders something rather than an error.
//
// The authenticated feed is deliberately NOT vetting-gated server-side: a
// pending member sees the public rows here and gets a real app rather than a
// blank screen, and the scope widens on its own once they're vetted.

extension APIClient {

    /// One page of announcements, choosing the right route for the caller's
    /// auth state. Admins get the admin list, which is the only one that
    /// includes drafts.
    func announcementsFeed(page: Int, per: Int, includeDrafts: Bool = false) async throws -> PagedResponse<Announcement> {
        let query = ["page": "\(page)", "per": "\(per)"]

        if includeDrafts, isAuthenticated {
            do {
                return try await get(APIClient.path("/api/admin/announcements", query: query))
            } catch let APIError.httpError(code, _) where code == 403 || code == 404 {
                // Not actually an admin (or the route moved) — fall through to
                // the member feed rather than showing an error.
            }
        }

        if isAuthenticated {
            do {
                return try await get(APIClient.path("/api/announcements", query: query))
            } catch let APIError.httpError(code, _) where code == 404 {
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

    /// Mark an announcement read. Fire-and-forget by nature: failing to record a
    /// read is not worth interrupting anyone over.
    func markAnnouncementRead(id: String) async {
        guard isAuthenticated else { return }
        try? await postVoid("/api/announcements/\(id)/read")
    }

    // MARK: - Admin
    //
    // Gated in the UI by `AuthUser.isAdmin`, and gated for real by the server's
    // `RequireAdmin` middleware. The client check decides what to draw; it never
    // decides what is allowed.

    @discardableResult
    func createAnnouncement(_ request: CreateAnnouncementRequest) async throws -> Announcement {
        try await post("/api/admin/announcements", body: request)
    }

    @discardableResult
    func updateAnnouncement(id: String, _ request: UpdateAnnouncementRequest) async throws -> Announcement {
        try await patch("/api/admin/announcements/\(id)", body: request)
    }

    func deleteAnnouncement(id: String) async throws {
        try await delete("/api/admin/announcements/\(id)")
    }

    /// Publish, and report what the push actually did. The server guards a
    /// re-publish with `push_sent_at`, so a second call returns
    /// `pushSkippedAlreadySent` rather than notifying everyone twice.
    @discardableResult
    func publishAnnouncement(id: String) async throws -> PublishResult {
        try await post("/api/admin/announcements/\(id)/publish")
    }

    @discardableResult
    func unpublishAnnouncement(id: String) async throws -> Announcement {
        try await post("/api/admin/announcements/\(id)/unpublish")
    }

    // MARK: - Notification preferences

    func notificationPreferences() async throws -> NotificationPreferences {
        try await get("/api/me/notifications")
    }

    @discardableResult
    func updateNotificationPreferences(_ update: NotificationPreferencesUpdate) async throws -> NotificationPreferences {
        try await put("/api/me/notifications", body: update)
    }
}
