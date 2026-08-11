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

    /// Photos or video, batched onto BOTH the feed and the detail route so a grid
    /// renders without a request per post. Signed URLs are good for an hour;
    /// `APIClient.postMedia(postId:)` refreshes a screen left open longer.
    ///
    /// Defaults to empty rather than being Optional: every consumer wants "the
    /// media, possibly none", and an Optional array would put a `?? []` at each of
    /// them.
    let media: [PostMediaDTO]

    // Providing `init(from:)` suppresses the synthesized `CodingKeys`, so it is
    // declared. Cases carry NO raw values on purpose: the decoder's
    // `.convertFromSnakeCase` turns `channel_slug` into `channelSlug` and then
    // matches on the case NAME, so spelling snake_case here would double-convert —
    // the same trap the DTO comments warn about everywhere else.
    private enum CodingKeys: String, CodingKey {
        case id, channelId, channelSlug, title, body, author, isPinned, isLocked
        case commentCount, reactionCount, myReaction, status, removalReason
        case lastActivityAt, createdAt, editedAt, canEdit, canDelete, canModerate, media
    }

    /// `media` is decoded leniently: a server that predates the media contract
    /// omits the key entirely, and a missing key must not fail the whole post.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        channelId = try c.decodeIfPresent(String.self, forKey: .channelId)
        channelSlug = try c.decodeIfPresent(String.self, forKey: .channelSlug)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        author = try c.decodeIfPresent(ForumAuthor.self, forKey: .author)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned)
        isLocked = try c.decodeIfPresent(Bool.self, forKey: .isLocked)
        commentCount = try c.decodeIfPresent(Int.self, forKey: .commentCount)
        reactionCount = try c.decodeIfPresent(Int.self, forKey: .reactionCount)
        myReaction = try c.decodeIfPresent(String.self, forKey: .myReaction)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        removalReason = try c.decodeIfPresent(String.self, forKey: .removalReason)
        lastActivityAt = try c.decodeIfPresent(Date.self, forKey: .lastActivityAt)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        editedAt = try c.decodeIfPresent(Date.self, forKey: .editedAt)
        canEdit = try c.decodeIfPresent(Bool.self, forKey: .canEdit)
        canDelete = try c.decodeIfPresent(Bool.self, forKey: .canDelete)
        canModerate = try c.decodeIfPresent(Bool.self, forKey: .canModerate)
        media = (try? c.decodeIfPresent([PostMediaDTO].self, forKey: .media)) as? [PostMediaDTO] ?? []
    }

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

/// `POST /api/admin/channels`. Mirrors the server's `CreateChannelRequest`.
///
/// **`slug` is required and immutable after creation** — `AdminChannelController`
/// deliberately leaves it out of the update route — so it is derived from the name
/// once, at creation, and never rewritten when the name changes later. Only `slug`
/// and `name` are required; the rest carry the server's own defaults
/// (`visibility: vetted`, `defaultRole: commenter`, `allowMedia: true`).
///
/// `defaultRole` accepts `commenter | poster` ONLY — the server refuses
/// `moderator` here with a 400, because a channel whose default role is moderator
/// would hand every vetted member the removal tools.
nonisolated struct CreateChannelRequest: Encodable, Sendable {
    let slug: String
    let name: String
    var description: String?
    var visibility: String?
    var defaultRole: String?
}

/// The two wire values the server's `ChannelVisibility` accepts. `public_read`
/// was cut server-side (§2.3), so there is no third case to render.
nonisolated enum ChannelVisibilityOption: String, CaseIterable, Identifiable, Sendable {
    case vetted
    case restricted = "private"   // `private` is a Swift keyword; the RAW value is the contract

    nonisolated var id: String { rawValue }

    var title: String {
        switch self {
        case .vetted:     return "Every vetted member"
        case .restricted: return "Invite only"
        }
    }

    var explanation: String {
        switch self {
        case .vetted:
            return "Anyone who's been vetted can read and take part."
        case .restricted:
            return "Only members you add can see it — it won't even appear in anyone else's list."
        }
    }
}

/// The role a member gets in a new channel unless an admin overrides it per person.
nonisolated enum ChannelDefaultRoleOption: String, CaseIterable, Identifiable, Sendable {
    case commenter
    case poster

    nonisolated var id: String { rawValue }

    var title: String {
        switch self {
        case .commenter: return "Comment only"
        case .poster:    return "Post and comment"
        }
    }

    var explanation: String {
        switch self {
        case .commenter:
            return "Members can reply to threads. Only the people you promote can start one."
        case .poster:
            return "Members can start threads as well as reply."
        }
    }
}

// MARK: - Slugs

nonisolated enum FWBSlug {
    /// The server's rule, applied here so the admin sees the slug before they
    /// commit to it: `^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$` — lowercase, 3–50
    /// characters, hyphen-separated, never starting or ending with a hyphen.
    ///
    /// Derived rather than typed because the slug is permanent and typing one is
    /// an invitation to typo something nobody can ever correct.
    static func kebab(from raw: String) -> String {
        var out = ""
        var lastWasHyphen = true   // seeded true so a leading separator is dropped
        for scalar in raw.lowercased().unicodeScalars {
            let isSlugCharacter = (scalar.value >= 97 && scalar.value <= 122)   // a–z
                || (scalar.value >= 48 && scalar.value <= 57)                   // 0–9
            if isSlugCharacter {
                out.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                out.append("-")
                lastWasHyphen = true
            }
        }
        // The prefix can re-introduce a trailing hyphen the loop had allowed, so
        // the trim happens after the truncation, not before it.
        var trimmed = String(out.prefix(50))
        while trimmed.hasSuffix("-") { trimmed.removeLast() }
        return trimmed
    }

    static func isValid(_ slug: String) -> Bool {
        (3...50).contains(slug.count)
    }
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
