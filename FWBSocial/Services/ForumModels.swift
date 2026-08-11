import Foundation

// MARK: - Forum wire models
//
// A field-for-field mirror of fwb-server's `ForumDTOs.swift`
// (Sources/App/Modules/Forum/), whose emitted snake_case keys are pinned by the
// server's `WireContractTests`. Both sides use `.convertFromSnakeCase`, so these
// property names ARE the contract.
//
// **No consecutive capitals, ever** — the same trap `AuthModels.swift` documents:
// `avatarURL` would encode to `avatar_url` but decode from it as `avatarUrl`, so
// the field silently fails to decode while the server looks healthy. Write
// `avatarUrl`, `sfSymbol`, `myReaction`.
//
// Optionality is looser here than on the server on purpose. The server declares
// most of these non-null and they are — but a required property that turns out to
// be absent throws `keyNotFound` and takes the whole channel down. An Optional
// costs a `??`.
//
// **Permissions are server-resolved and never inferred here.** `canPost`,
// `canEdit`, `canDelete`, `canModerate` arrive per-row from `ChannelAccess`
// (plan §4.2: "never inferred client-side, never duplicated"). This client uses
// them to decide what to *draw*; the server decides what is *allowed*.

// MARK: - Author

/// The discovery surface. Commissioner decision 9 removes member search
/// entirely, so the only route to a person is reading something they wrote and
/// tapping through — which makes `id` load-bearing rather than incidental.
///
/// Deliberately carries no `friendCode`: a friend code is a shared secret handed
/// out deliberately, not something to broadcast on every comment in a channel.
nonisolated struct ForumAuthor: Decodable, Sendable, Equatable, Hashable, Identifiable {
    let id: String
    let displayName: String?
    let username: String?
    let avatarUrl: String?

    /// Whether this author accepts friend requests arising from forum
    /// interactions. Decides whether the button is offered at all, rather than
    /// offering one that will be refused.
    let allowsFriendRequests: Bool?

    /// True when the account is gone. Plan §6.1 tombstones forum authorship
    /// rather than cascading a deletion through everyone else's threads.
    let isDeleted: Bool?

    var name: String { isTombstoned ? "Deleted member" : (displayName ?? "Member") }
    var isTombstoned: Bool { isDeleted ?? false }
    var acceptsFriendRequests: Bool { allowsFriendRequests ?? false }

    /// A tombstoned author has no profile to open — suppress the tap rather than
    /// pushing a sheet about someone who isn't there.
    var isTappable: Bool { !isTombstoned }

    var handle: String? { username.map { "@\($0)" } }
}

// MARK: - Channel

nonisolated struct Channel: Decodable, Sendable, Identifiable, Equatable {
    let id: String
    let slug: String
    let name: String?
    let description: String?
    let sfSymbol: String?
    let accentHex: String?
    let sortOrder: Int?
    /// `vetted` | `private`. `public_read` was cut server-side (§2.3).
    let visibility: String?
    let isArchived: Bool?

    /// The caller's **resolved** role, never the channel's default. A channel the
    /// caller cannot access is omitted from the list entirely rather than
    /// arriving with a null role, so there is no "no access" case to render.
    let effectiveRole: String?
    let canPost: Bool?
    let canComment: Bool?
    let canModerate: Bool?
    let muted: Bool?
    let postCount: Int?

    var displayName: String { name?.isEmpty == false ? name! : slug }
    var symbol: String { sfSymbol?.isEmpty == false ? sfSymbol! : "bubble.left.and.bubble.right" }
    var mayPost: Bool { canPost ?? false }
    var mayComment: Bool { canComment ?? false }
    var mayModerate: Bool { canModerate ?? false }
    var isMuted: Bool { muted ?? false }
    var archived: Bool { isArchived ?? false }
    var isPrivate: Bool { visibility == "private" }
    var posts: Int { postCount ?? 0 }

    /// The role badge worth showing. `commenter` is the floor and drawing a badge
    /// for it would put a label on every row, which is noise.
    var roleBadge: String? {
        switch effectiveRole {
        case "moderator": return "Moderator"
        case "poster":    return "Poster"
        default:          return nil
        }
    }
}

// MARK: - Post

nonisolated struct ForumPost: Decodable, Sendable, Identifiable, Equatable {
    let id: String
    let channelId: String?
    let channelSlug: String?
    let title: String?
    let body: String?
    let author: ForumAuthor?
    let isPinned: Bool?
    let isLocked: Bool?
    let commentCount: Int?
    let reactionCount: Int?

    /// The caller's own reaction, so the control renders its selected state with
    /// no second request.
    let myReaction: String?

    /// `published` | `removed`.
    let status: String?
    let removalReason: String?
    let lastActivityAt: Date?
    let createdAt: Date?
    let editedAt: Date?

    let canEdit: Bool?
    let canDelete: Bool?
    let canModerate: Bool?

    var displayTitle: String { title?.isEmpty == false ? title! : "Untitled" }
    var displayBody: String { body ?? "" }
    var pinned: Bool { isPinned ?? false }
    var locked: Bool { isLocked ?? false }
    var comments: Int { commentCount ?? 0 }
    var reactions: Int { reactionCount ?? 0 }
    var mayEdit: Bool { canEdit ?? false }
    var mayDelete: Bool { canDelete ?? false }
    var mayModerate: Bool { canModerate ?? false }
    var isRemoved: Bool { status == "removed" }
    var wasEdited: Bool { editedAt != nil }
    var timestamp: Date? { createdAt ?? lastActivityAt }
}

// MARK: - Comment

nonisolated struct ForumComment: Decodable, Sendable, Identifiable, Equatable {
    let id: String
    let postId: String?
    /// One level of nesting only (§2.3). The server re-parents a reply-to-a-reply
    /// onto the top-level comment rather than rejecting it, so this is either nil
    /// or a top-level comment's id — never a chain.
    let parentCommentId: String?
    let body: String?
    let author: ForumAuthor?
    let reactionCount: Int?
    let myReaction: String?
    let status: String?
    let createdAt: Date?
    let editedAt: Date?
    let canEdit: Bool?
    let canDelete: Bool?

    var displayBody: String { body ?? "" }
    var reactions: Int { reactionCount ?? 0 }
    var mayEdit: Bool { canEdit ?? false }
    var mayDelete: Bool { canDelete ?? false }
    var isRemoved: Bool { status == "removed" }
    var wasEdited: Bool { editedAt != nil }
    var isReply: Bool { parentCommentId != nil }
}

/// `GET /api/posts/:id/comments` — a flat `{ items, total }`, not paginated.
/// A thread is read whole; paginating it would mean a "load more" between a
/// question and its answer.
nonisolated struct CommentListResponse: Decodable, Sendable {
    let items: [ForumComment]
    let total: Int?
}

// MARK: - Write payloads

nonisolated struct CreatePostRequest: Encodable, Sendable {
    let title: String
    let body: String
}

nonisolated struct UpdatePostRequest: Encodable, Sendable {
    var title: String?
    var body: String?
}

nonisolated struct CreateCommentRequest: Encodable, Sendable {
    let body: String
    var parentCommentId: String?
}

nonisolated struct UpdateCommentRequest: Encodable, Sendable {
    let body: String
}

nonisolated struct SetReactionRequest: Encodable, Sendable {
    let reactionType: String
}

nonisolated struct SetPinnedRequest: Encodable, Sendable {
    let isPinned: Bool
}

nonisolated struct SetLockedRequest: Encodable, Sendable {
    let isLocked: Bool
}

nonisolated struct MuteChannelRequest: Encodable, Sendable {
    let muted: Bool
}

nonisolated struct ModerationActionRequest: Encodable, Sendable {
    var reason: String?
}

// MARK: - Reactions
//
// The server keeps `reaction_type` **opaque** (`SetReactionRequest.reactionType`,
// a short token it never interprets) precisely so the set is a client decision —
// adding one here needs no server deploy. Ported in spirit from MyStickyApp's
// `ReactionLikeControl`, which is also a five-way fan-out.

nonisolated enum FWBReaction: String, CaseIterable, Sendable, Identifiable {
    case like
    case heart
    case laugh
    case wow
    case sad

    nonisolated var id: String { rawValue }

    var emoji: String {
        switch self {
        case .like:  return "👍"
        case .heart: return "❤️"
        case .laugh: return "😂"
        case .wow:   return "😮"
        case .sad:   return "😢"
        }
    }

    var label: String {
        switch self {
        case .like:  return "Like"
        case .heart: return "Love"
        case .laugh: return "Haha"
        case .wow:   return "Wow"
        case .sad:   return "Sad"
        }
    }

    /// Tolerant of a token this build doesn't know: a reaction added by a newer
    /// client should render as *something* rather than vanishing.
    static func from(_ token: String?) -> FWBReaction? {
        guard let token, !token.isEmpty else { return nil }
        return FWBReaction(rawValue: token)
    }
}
