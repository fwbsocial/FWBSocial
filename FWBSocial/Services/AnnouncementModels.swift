import Foundation

// MARK: - Announcement
//
// PLAN.md §2.2 / §4.1. Modeled against the plan's `fwb_announcements` columns
// rather than a deployed response, because the server side is being built in
// parallel — so every field except `id` is Optional and the view layer degrades
// instead of failing. A required field that turns out to be absent takes the
// whole feed down; an Optional one costs a `??`.
//
// Author shape is accepted in three forms because there are three reasonable
// ways to serialise it and guessing wrong shouldn't cost a round of integration:
// a nested `author` object, a flat `author_display_name`, or nothing at all.

nonisolated struct Announcement: Decodable, Sendable, Identifiable, Equatable {
    let id: String
    let title: String?
    let body: String?

    /// `public` | `vetted` (PLAN.md §2.2). `public` rows are the ones the
    /// signed-out Home tab shows.
    let visibility: String?
    /// `draft` | `published`.
    let status: String?
    let isPinned: Bool?
    let publishedAt: Date?
    let createdAt: Date?
    let updatedAt: Date?

    /// Read state, present only on the authenticated feed.
    let readAt: Date?

    /// Hero media. `heroMediaUrl` is a resolved URL if the server hands one
    /// back; `heroMediaKey` is the raw R2 key, which is useless to the client on
    /// its own (R2 is not provisioned — PLAN.md Phase 0) but is kept so the
    /// field isn't silently dropped.
    let heroMediaUrl: String?
    let heroMediaKey: String?

    let author: AnnouncementAuthor?
    let authorDisplayName: String?

    var displayTitle: String { title?.isEmpty == false ? title! : "Untitled" }
    var displayBody: String { body ?? "" }
    var isPublished: Bool { status == nil || status == "published" }
    var pinned: Bool { isPinned ?? false }
    var isUnread: Bool { readAt == nil }
    var isVettedOnly: Bool { visibility == "vetted" }

    var authorName: String? {
        author?.displayName ?? authorDisplayName
    }

    /// The timestamp worth showing: when it was published, falling back to when
    /// it was written.
    var timestamp: Date? { publishedAt ?? createdAt }
}

nonisolated struct AnnouncementAuthor: Decodable, Sendable, Equatable {
    let id: String?
    let displayName: String?
    let avatarUrl: String?
}

// MARK: - Admin write payloads

/// Create/update body for `POST|PATCH /api/admin/announcements`.
///
/// `nil` means "leave alone" on PATCH, so the composer sends only what changed.
nonisolated struct AnnouncementDraft: Encodable, Sendable {
    var title: String?
    var body: String?
    var visibility: String?
    var isPinned: Bool?
    /// Included on create so an admin can save a draft without publishing it.
    var status: String?
}
