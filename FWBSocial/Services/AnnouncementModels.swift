import Foundation

// MARK: - Announcement
//
// A mirror of fwb-server's `AnnouncementResponse`
// (Sources/App/Modules/Announcements/AnnouncementDTOs.swift), verified against
// the deployed route rather than inferred from the plan.
//
// Optionality is looser here than on the server on purpose. The server declares
// `title`, `body`, `visibility`, `status` and `isPinned` non-null, and they are
// — but this client also has to survive a server mid-deploy and a route that
// gains a field. A required property that turns out to be absent throws
// `keyNotFound` and takes the entire feed down; an Optional one costs a `??`.
//
// `isRead` is nil for signed-out callers, where read state is meaningless. That
// distinction matters: nil is "no account", `false` is "unread".

nonisolated struct Announcement: Decodable, Sendable, Identifiable, Equatable {
    let id: String
    let title: String?
    let body: String?

    /// `public` | `vetted` (PLAN.md §2.2). `public` rows are what the signed-out
    /// Home tab shows.
    let visibility: String?
    /// `draft` | `published`.
    let status: String?
    let isPinned: Bool?
    /// When the pin is scheduled to lapse, or nil for "pinned until an admin
    /// unpins it by hand". The server's five-minute sweep is what actually clears
    /// it; this is only ever what the admin sees on the card.
    let pinnedUntil: Date?
    let publishedAt: Date?
    let createdAt: Date?
    let updatedAt: Date?

    /// Read state — nil when unauthenticated.
    let isRead: Bool?

    /// Resolved hero URL. The write side takes a `hero_media_key`; the read side
    /// hands back a URL. R2 isn't provisioned yet (PLAN.md Phase 0), so in
    /// practice this is nil today.
    let heroUrl: String?

    let authorName: String?

    var displayTitle: String { title?.isEmpty == false ? title! : "Untitled" }
    var displayBody: String { body ?? "" }
    var isPublished: Bool { status == nil || status == "published" }
    var isDraft: Bool { status == "draft" }
    var pinned: Bool { isPinned ?? false }
    var isVettedOnly: Bool { visibility == "vetted" }

    /// "Pinned until Aug 15" — admin-only chrome, because a member has no idea
    /// what a pin is and no way to change one.
    var pinScheduleLabel: String? {
        guard pinned, let pinnedUntil else { return nil }
        return "Pinned until \(AnnouncementActions.pinDateText(pinnedUntil))"
    }

    /// What "Share" hands to the share sheet, defined once so the kebab's Share
    /// and the non-admin toolbar's share are the same thing.
    var shareText: String {
        displayBody.isEmpty ? displayTitle : "\(displayTitle)\n\n\(displayBody)"
    }

    /// Only meaningful with a session — a signed-out reader has no read state,
    /// and drawing an unread dot for them would be noise.
    var isUnread: Bool { isRead == false }

    /// The timestamp worth showing: when it was published, falling back to when
    /// it was written.
    var timestamp: Date? { publishedAt ?? createdAt }
}

// MARK: - Admin write payloads

/// `POST /api/admin/announcements` — `CreateAnnouncementRequest`. Title and body
/// are required; visibility defaults to `public` server-side.
nonisolated struct CreateAnnouncementRequest: Encodable, Sendable {
    let title: String
    let body: String
    var visibility: String?
    var heroMediaKey: String?
    var isPinned: Bool?
    /// Optional scheduled unpin, only meaningful alongside `isPinned: true` — the
    /// server clears it on anything that is not pinned.
    var pinnedUntil: Date?
}

/// `PATCH /api/admin/announcements/:id` — `UpdateAnnouncementRequest`. Every
/// field is Optional and an omitted one is left alone.
nonisolated struct UpdateAnnouncementRequest: Encodable, Sendable {
    var title: String?
    var body: String?
    var visibility: String?
    var heroMediaKey: String?
    var isPinned: Bool?
    /// Set or move the scheduled unpin.
    var pinnedUntil: Date?
    /// Remove the schedule while staying pinned. A separate flag because omission
    /// on this DTO already means "leave alone", so a nil date cannot also mean
    /// "clear it" — the two are the same bytes on the wire.
    var clearPinnedUntil: Bool?
}

/// What `POST /api/admin/announcements/:id/publish` returns.
///
/// `pushDelivered` is surfaced in the UI rather than assumed: zero is a normal
/// outcome (nobody opted in, APNs not configured, everyone toggled it off), and
/// an admin who is told "published" while nothing was delivered has been
/// misled. `pushSkippedAlreadySent` is the re-publish guard — `push_sent_at`
/// stops a second publish double-notifying the membership.
nonisolated struct PublishResult: Decodable, Sendable {
    let announcement: Announcement
    let pushDelivered: Int?
    let pushSkippedAlreadySent: Bool?
}

// MARK: - Notification preferences
//
// `GET|PUT /api/me/notifications`. A dedicated route rather than a corner of the
// profile update, which is what the server offers and what the toggles use.

nonisolated struct NotificationPreferences: Codable, Sendable, Equatable {
    var notifyAnnouncements: Bool
    var notifyDm: Bool
    var notifyFriendRequests: Bool
    var notifyChannelPosts: Bool

    /// Commissioner decision 9's per-user switch. **Not a notification setting**,
    /// but the server put it on this endpoint on purpose — it belongs to the same
    /// settings screen, and giving it its own route would have meant a second
    /// endpoint two phases from now. Defaulted true to match the server's column
    /// default, so a server that predates the field doesn't read as "off".
    var allowForumFriendRequests: Bool = true
}

nonisolated struct NotificationPreferencesUpdate: Encodable, Sendable {
    var notifyAnnouncements: Bool?
    var notifyDm: Bool?
    var notifyFriendRequests: Bool?
    var notifyChannelPosts: Bool?
    var allowForumFriendRequests: Bool?
}
