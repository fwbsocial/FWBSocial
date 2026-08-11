import Foundation

// MARK: - Chat REST
//
// Cove's `CommuneAPI` was 841 LoC because it carried its own Bearer plumbing, its
// own Keychain token store, and its own single-flight 401→refresh→retry. FWBSocial
// already has all three in `APIClient` + `KeychainHelper` + `AuthService`, and the
// brief is explicit: ONE token store, not two auth systems. So the transport is
// dropped wholesale and what remains is the typed endpoint surface — which is the
// part that was actually worth porting.
//
// Every path below is verified against fwb-server's `routes.swift`. The chat group
// sits behind `RequireVettedMember` EXCEPT `PUT /api/chat/devices`, which is
// deliberately reachable by a `pending` member (§4.6) so the TOFU root is minted at
// first login and chat simply works the moment vetting flips.

@MainActor
enum ChatAPI {

    private static var api: APIClient { APIClient.shared }

    // MARK: - Devices

    /// `PUT /api/chat/devices` — register or re-register. Upsert key is
    /// `(user_id, identity_key)`, so re-registering the same device is idempotent
    /// rather than a second row.
    static func registerDevice(_ body: RegisterDeviceRequest) async throws -> ChatDeviceDTO {
        try await api.put("/api/chat/devices", body: body)
    }

    static func myDevices() async throws -> [ChatDeviceDTO] {
        try await api.get("/api/chat/devices")
    }

    static func approveDevice(_ deviceId: UUID, body: ApproveDeviceRequest) async throws -> ChatDeviceDTO {
        try await api.post("/api/chat/devices/\(deviceId.uuidString)/approve", body: body)
    }

    static func revokeDevice(_ deviceId: UUID) async throws {
        try await api.postVoid("/api/chat/devices/\(deviceId.uuidString)/revoke")
    }

    /// A peer's active + approved devices — the wrap targets. Gated server-side on a
    /// shared conversation, so this 403s for someone you have no thread with.
    static func peerDevices(userId: UUID) async throws -> [ChatDeviceDTO] {
        try await api.get("/api/chat/devices/peer/\(userId.uuidString)")
    }

    // MARK: - Conversations

    static func conversations() async throws -> [ConversationDTO] {
        try await api.get("/api/chat/conversations")
    }

    static func conversation(_ id: UUID) async throws -> ConversationDTO {
        try await api.get("/api/chat/conversations/\(id.uuidString)")
    }

    /// Enforcement point for §4.4 — inbox privacy and the pairwise block rule both
    /// live here server-side. A `409 blocked_pair` names neither party, and a block
    /// in either direction reads as a 404.
    static func createConversation(_ body: CreateConversationRequest) async throws -> ConversationDTO {
        try await api.post("/api/chat/conversations", body: body)
    }

    static func updateConversation(_ id: UUID, body: UpdateConversationRequest) async throws -> ConversationDTO {
        try await api.patch("/api/chat/conversations/\(id.uuidString)", body: body)
    }

    /// The second §4.4 enforcement point. Note the server revives soft-removed rows
    /// here and runs both gates on the revival — removal-then-re-add is not a bypass.
    static func addMembers(_ id: UUID, userIds: [UUID]) async throws -> ConversationDTO {
        try await api.post("/api/chat/conversations/\(id.uuidString)/members", body: AddMembersRequest(userIds: userIds))
    }

    static func removeMember(_ id: UUID, userId: UUID) async throws -> ConversationDTO {
        try await api.delete(
            "/api/chat/conversations/\(id.uuidString)/members/\(userId.uuidString)",
            as: ConversationDTO.self
        )
    }

    /// Greys out a Message button rather than failing after composition. The shape
    /// is identical for every refusal — do not try to derive a reason from it.
    static func canMessage(userId: UUID) async throws -> CanMessageResponse {
        try await api.get("/api/chat/can-message/\(userId.uuidString)")
    }

    // MARK: - Messages

    /// `device` selects which wrapped key comes back. A newly approved device sees
    /// history rows with a **nil** key until A2's handoff runs — by design.
    static func history(
        conversationId: UUID,
        before: Date? = nil,
        limit: Int = 50,
        device: UUID?
    ) async throws -> MessagePageResponse {
        let path = APIClient.path(
            "/api/chat/conversations/\(conversationId.uuidString)/messages",
            query: [
                "limit": String(limit),
                "before": before.map(FWBDate.wire),
                "device": device?.uuidString,
            ]
        )
        return try await api.get(path)
    }

    static func send(conversationId: UUID, body: SendMessageRequest) async throws -> ChatMessageDTO {
        try await api.post("/api/chat/conversations/\(conversationId.uuidString)/messages", body: body)
    }

    static func message(_ id: UUID, device: UUID?) async throws -> ChatMessageDTO {
        let path = APIClient.path("/api/chat/messages/\(id.uuidString)", query: ["device": device?.uuidString])
        return try await api.get(path)
    }

    @discardableResult
    static func markSeen(conversationId: UUID, lastReadMessageId: UUID) async throws -> UnreadCountResponse {
        try await api.post(
            "/api/chat/conversations/\(conversationId.uuidString)/seen",
            body: MarkSeenRequest(lastReadMessageId: lastReadMessageId)
        )
    }

    static func unreadCount() async throws -> UnreadCountResponse {
        try await api.get("/api/chat/unread-count")
    }

    /// Toggling: sending the same emoji twice removes it, server-side.
    static func react(messageId: UUID, emoji: String) async throws {
        let _: EmptyResponse = try await api.request(
            "PUT",
            "/api/chat/messages/\(messageId.uuidString)/reactions",
            body: try FWBJSON.encoder.encode(ReactToMessageRequest(emoji: emoji))
        )
    }

    /// Sender only, and a HARD delete server-side. It stops the message being served
    /// again; it cannot remove it from another participant's device, and the UI says
    /// so rather than implying otherwise.
    static func deleteMessage(_ id: UUID) async throws {
        try await api.delete("/api/chat/messages/\(id.uuidString)")
    }

    // MARK: - Group keys

    static func uploadGroupKeys(conversationId: UUID, body: UploadGroupKeysRequest) async throws {
        try await api.postVoid("/api/chat/conversations/\(conversationId.uuidString)/group-keys", body: body)
    }

    /// Every version this device holds — a client needs the old ones to open history
    /// encrypted under an earlier key, not just current traffic.
    static func groupKeys(conversationId: UUID, device: UUID) async throws -> [GroupKeyDTO] {
        let path = APIClient.path(
            "/api/chat/conversations/\(conversationId.uuidString)/group-keys",
            query: ["device": device.uuidString]
        )
        return try await api.get(path)
    }

    // MARK: - A2 history handoff

    static func startHandoff(source: UUID, target: UUID) async throws -> HandoffStatusResponse {
        try await api.post("/api/chat/handoffs", body: StartHandoffRequest(sourceDeviceId: source, targetDeviceId: target))
    }

    static func handoffStatus(_ id: UUID) async throws -> HandoffStatusResponse {
        try await api.get("/api/chat/handoffs/\(id.uuidString)")
    }

    static func handoffPending(_ id: UUID, limit: Int = 200) async throws -> HandoffPendingResponse {
        let path = APIClient.path("/api/chat/handoffs/\(id.uuidString)/pending", query: ["limit": String(limit)])
        return try await api.get(path)
    }

    static func uploadHandoffBatch(_ body: HandoffBatchRequest) async throws -> HandoffStatusResponse {
        try await api.post("/api/chat/handoffs/batch", body: body)
    }

    static func cancelHandoff(_ id: UUID) async throws -> HandoffStatusResponse {
        try await api.delete("/api/chat/handoffs/\(id.uuidString)", as: HandoffStatusResponse.self)
    }

    // MARK: - Media
    //
    // Both routes degrade to **503 with a renderable reason** while R2 is
    // unprovisioned — deliberately not a 500, which reads as "your request broke us"
    // and invites a retry loop. The UI surfaces the server's sentence.

    static func mediaUploadURL(
        conversationId: UUID,
        contentType: String,
        byteSize: Int,
        needsThumbnail: Bool
    ) async throws -> MediaUploadURLResponse {
        try await api.post(
            "/api/chat/conversations/\(conversationId.uuidString)/media/upload-url",
            body: MediaUploadURLRequest(
                contentType: contentType,
                byteSize: byteSize,
                needsThumbnail: needsThumbnail
            )
        )
    }

    static func mediaDownloadURL(messageId: UUID) async throws -> MediaDownloadURLResponse {
        try await api.get("/api/chat/messages/\(messageId.uuidString)/media")
    }

    /// Direct PUT to the presigned R2 URL. Deliberately NOT through `APIClient` —
    /// this request must carry no bearer token (R2 would reject the extra header on
    /// a signed URL) and the bytes never transit the API server.
    static func uploadToPresignedURL(_ urlString: String, data: Data, contentType: String) async throws {
        guard let url = URL(string: urlString) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        let (_, response) = try await URLSession.shared.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0, message: "Upload failed")
        }
    }

    static func downloadFromPresignedURL(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0, message: "Download failed")
        }
        return data
    }
}

// MARK: - Friends
//
// PLAN.md Phase 6 ports the friend graph alongside chat for a blunt reason: chat is
// untestable without it. `inbox_policy` defaults to `friends_only`, so with no
// friends nobody can message anybody.
//
// **There is no search endpoint and there must never be one** (commissioner
// decision 9). Discovery is exactly three paths: an exact friend-code lookup, a
// post-event friending window (Phase 7), and tapping a member on their forum post —
// which the recipient can turn off.

@MainActor
enum FriendsAPI {

    private static var api: APIClient { APIClient.shared }

    static func friends() async throws -> [FriendDTO] {
        try await api.get("/api/friends")
    }

    static func incomingRequests() async throws -> [FriendRequestDTO] {
        try await api.get("/api/friends/requests")
    }

    static func sendRequest(to userId: UUID, source: FriendRequestSource, eventId: String? = nil) async throws -> FriendRequestDTO {
        try await api.post(
            "/api/friends/requests",
            body: SendFriendRequestBody(toUserId: userId, source: source.rawValue, eventId: eventId)
        )
    }

    static func accept(_ requestId: UUID) async throws -> FriendRequestDTO {
        try await api.post("/api/friends/requests/\(requestId.uuidString)/accept")
    }

    static func decline(_ requestId: UUID) async throws -> FriendRequestDTO {
        try await api.post("/api/friends/requests/\(requestId.uuidString)/decline")
    }

    static func unfriend(_ userId: UUID) async throws {
        try await api.delete("/api/friends/\(userId.uuidString)")
    }

    /// Exact match on an 8-character shared secret — not a reinstatement of member
    /// search. Rate-limited server-side (20 per 5 minutes) because a code that short
    /// would otherwise be enumerable, and it returns ONE shape for "no such code",
    /// "that's you" and "blocked".
    static func lookup(code: String) async throws -> FriendCodeLookupResponse {
        let path = APIClient.path("/api/friends/lookup", query: ["code": code.uppercased()])
        return try await api.get(path)
    }
}

nonisolated enum FriendRequestSource: String, Sendable {
    case friendCode = "friend_code"
    case event
    case forumProfile = "forum_profile"
}

// MARK: - Wire date helper

extension FWBDate {
    /// ISO8601 without fractional seconds — the format fwb-server's global encoder
    /// emits and its `req.query[Date.self]` decoder accepts. Used for the `before=`
    /// history cursor, which is a query parameter and so cannot ride the JSON coder.
    nonisolated static func wire(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
