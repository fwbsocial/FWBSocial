import Foundation

// MARK: - Forum endpoints
//
// Verified against the deployed fwb-server's `routes.swift` (plan §4.2):
//
//   GET    /api/channels                       list (array, not paginated)
//   GET    /api/channels/:slug/posts           feed  { items,total,page,per,has_more }
//   POST   /api/channels/:slug/posts           create post   (403 unless ≥ poster)
//   PUT    /api/channels/:slug/mute            per-channel mute
//   GET    /api/posts/:id                      post detail
//   PATCH  /api/posts/:id                      edit  (AUTHOR ONLY, not moderators)
//   DELETE /api/posts/:id                      remove (author or moderator)
//   POST   /api/posts/:id/pin | /lock          moderator
//   GET    /api/posts/:id/comments             { items, total } — flat, unpaginated
//   POST   /api/posts/:id/comments             (403 unless ≥ commenter)
//   PATCH  /api/comments/:id                   edit (author only)
//   DELETE /api/comments/:id                   remove (author or moderator)
//   PUT|DELETE /api/{posts,comments}/:id/reactions
//
// Everything above sits behind `RequireVettedMember`, so a `pending` member gets
// 403 on all of it. That is why `ChannelsView` renders a vetting-status screen
// rather than an error — a pending member has a real app (plan §4.6), just not
// this part of it.
//
// **The reaction routes return no body** (`.ok` / `.noContent`). That is the
// reason reactions are applied optimistically and reconciled from the next
// fetch: there is no server echo to adopt.

extension APIClient {

    // MARK: - Channels

    /// Only channels the caller can access, each with a resolved role. Private
    /// channels the caller isn't in are omitted entirely — there is no
    /// "no access" row to filter out here.
    func channels() async throws -> [Channel] {
        try await get("/api/channels")
    }

    /// One page of a channel's posts. Pinned first, then most-recent activity —
    /// the server's ordering, which the client must not re-sort or the pinned
    /// block would drift out of place across pages.
    func channelPosts(slug: String, page: Int, per: Int) async throws -> PagedResponse<ForumPost> {
        try await get(APIClient.path("/api/channels/\(slug)/posts",
                                     query: ["page": "\(page)", "per": "\(per)"]))
    }

    @discardableResult
    func setChannelMuted(slug: String, muted: Bool) async throws -> Channel {
        try await put("/api/channels/\(slug)/mute", body: MuteChannelRequest(muted: muted))
    }

    // MARK: - Posts

    @discardableResult
    func createPost(slug: String, title: String, body: String) async throws -> ForumPost {
        try await post("/api/channels/\(slug)/posts",
                       body: CreatePostRequest(title: title, body: body))
    }

    func post(id: String) async throws -> ForumPost {
        try await get("/api/posts/\(id)")
    }

    @discardableResult
    func updatePost(id: String, title: String?, body: String?) async throws -> ForumPost {
        try await patch("/api/posts/\(id)", body: UpdatePostRequest(title: title, body: body))
    }

    /// Removes a post. Always a status transition server-side, never a row
    /// delete — a hard delete would cascade the thread's comments and destroy
    /// other people's words along with it.
    func deletePost(id: String) async throws {
        try await delete("/api/posts/\(id)")
    }

    @discardableResult
    func setPostPinned(id: String, pinned: Bool) async throws -> ForumPost {
        try await post("/api/posts/\(id)/pin", body: SetPinnedRequest(isPinned: pinned))
    }

    @discardableResult
    func setPostLocked(id: String, locked: Bool) async throws -> ForumPost {
        try await post("/api/posts/\(id)/lock", body: SetLockedRequest(isLocked: locked))
    }

    // MARK: - Comments

    func comments(postId: String) async throws -> CommentListResponse {
        try await get("/api/posts/\(postId)/comments")
    }

    @discardableResult
    func createComment(postId: String, body: String, parentCommentId: String? = nil) async throws -> ForumComment {
        try await post("/api/posts/\(postId)/comments",
                       body: CreateCommentRequest(body: body, parentCommentId: parentCommentId))
    }

    @discardableResult
    func updateComment(id: String, body: String) async throws -> ForumComment {
        try await patch("/api/comments/\(id)", body: UpdateCommentRequest(body: body))
    }

    func deleteComment(id: String) async throws {
        try await delete("/api/comments/\(id)")
    }

    // MARK: - Reactions
    //
    // Swap-in-place server-side: one row per (target, member), the type replaced
    // rather than a second row added, so a double tap cannot inflate the count.
    // Re-reacting with the same type is a no-op.

    func setPostReaction(id: String, reaction: FWBReaction) async throws {
        let _: EmptyResponse = try await request(
            "PUT", "/api/posts/\(id)/reactions",
            body: try FWBJSON.encoder.encode(SetReactionRequest(reactionType: reaction.rawValue)))
    }

    func clearPostReaction(id: String) async throws {
        try await delete("/api/posts/\(id)/reactions")
    }

    func setCommentReaction(id: String, reaction: FWBReaction) async throws {
        let _: EmptyResponse = try await request(
            "PUT", "/api/comments/\(id)/reactions",
            body: try FWBJSON.encoder.encode(SetReactionRequest(reactionType: reaction.rawValue)))
    }

    func clearCommentReaction(id: String) async throws {
        try await delete("/api/comments/\(id)/reactions")
    }
}
