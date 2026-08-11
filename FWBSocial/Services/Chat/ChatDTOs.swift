import Foundation

// MARK: - Chat wire models
//
// A field-for-field mirror of fwb-server's `Sources/App/Modules/Chat/DTOs/ChatDTOs.swift`
// and `Sources/App/Modules/Social/` friend shapes. PLAN.md §5.2 asks for Cove's
// `CommuneDTOs` (874 LoC) "pruned to the server's actual wire" — this is that prune,
// written against the deployed contract rather than the source's.
//
// TWO WIRE RULES, both enforced by the server's `WireContractTests` and both silent
// killers when broken:
//
//   1. **No explicit snake_case `CodingKeys`.** Both sides use
//      `.convertToSnakeCase` / `.convertFromSnakeCase`, so the property names ARE
//      the contract. A hand-written `CodingKeys` that spells the snake_case name
//      gets converted a second time and produces `encrypted__content`.
//
//   2. **No consecutive capitals, no digit-adjacent letters.** Foundation's
//      conversion is not symmetric across them: `senderDeviceID` encodes to
//      `sender_device_id` but `sender_device_id` decodes to `senderDeviceId`, so the
//      field silently fails to decode while the server looks perfectly healthy.
//      Write `deviceId`, `avatarUrl`, `isQuantumSecure`.
//
// Everything the server models as nullable is Optional here. A wire-nullable field
// typed non-optional throws `valueNotFound` and takes the whole response down.

// MARK: - Devices

nonisolated struct RegisterDeviceRequest: Encodable, Sendable {
    let deviceName: String
    let platform: String
    let identityKey: String
    let signingPublicKey: String?
    let quantumPublicKey: String
    /// `Sign_signingKey(rawBytesOf(quantumPublicKey))`. The server VERIFIES this —
    /// see `ChatEncryptionService.keyBindingSignaturePayload` for why it is the raw
    /// key bytes and not Cove's domain-separated string.
    let keySignature: String
    let enrolledByDeviceId: UUID?
    let approvalSignature: String?
}

nonisolated struct ChatDeviceDTO: Decodable, Sendable, Identifiable, Equatable {
    let id: UUID
    let userId: UUID
    let deviceName: String
    let platform: String
    let identityKey: String
    let signingPublicKey: String?
    let quantumPublicKey: String
    let keySignature: String
    let isActive: Bool
    let isApproved: Bool
    /// True when THIS registration self-promoted to the trust root (§4.3.3(A)).
    /// Only meaningful on the response to `PUT /api/chat/devices`; the list route
    /// returns false for every row.
    let isRoot: Bool
    /// Whether the server could verify the classical↔PQ binding. Surfaced so the UI
    /// can warn rather than silently trusting an unverifiable device.
    let bindingVerified: Bool
    let lastActiveAt: Date?
    let createdAt: Date?

    /// A device this client may wrap keys to, before trust evaluation.
    var isUsable: Bool { isActive && isApproved }

    /// A device with no enrolling parent is a TOFU root. The server does not return
    /// `enrolled_by_device_id`, so the approval-chain check runs over what the client
    /// itself recorded at approval time — see `DeviceTrustStore`.
    static func == (lhs: ChatDeviceDTO, rhs: ChatDeviceDTO) -> Bool { lhs.id == rhs.id }
}

nonisolated struct ApproveDeviceRequest: Encodable, Sendable {
    let approvalSignature: String
    let approvedByDeviceId: UUID
}

// MARK: - Conversations

nonisolated struct CreateConversationRequest: Encodable, Sendable {
    let isGroup: Bool
    let title: String?
    let participantIds: [UUID]
    /// Absent means TRUE server-side. We send it explicitly anyway so the intent is
    /// legible on the wire; PLAN.md §2.4 forbids relaxing the default.
    let requireQuantum: Bool?
}

nonisolated struct AddMembersRequest: Encodable, Sendable {
    let userIds: [UUID]
}

nonisolated struct ConversationDTO: Decodable, Sendable, Identifiable, Equatable {
    let id: UUID
    let isGroup: Bool
    let title: String?
    let avatarUrl: String?
    let createdBy: UUID?
    let requireQuantum: Bool
    let currentGroupKeyVersion: Int
    /// The message TTL override. Nil = off. PLAN.md §2.8 / commissioner decision 10
    /// put the server default at 365 days; the per-conversation choices are
    /// 30 / 90 / 365 / off.
    let disappearingSeconds: Int?
    let lastMessageAt: Date?
    let memberIds: [UUID]
    let unreadCount: Int
    let muted: Bool
    let createdAt: Date?

    static func == (lhs: ConversationDTO, rhs: ConversationDTO) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.lastMessageAt == rhs.lastMessageAt
            && lhs.unreadCount == rhs.unreadCount
            && lhs.muted == rhs.muted
            && lhs.memberIds == rhs.memberIds
            && lhs.currentGroupKeyVersion == rhs.currentGroupKeyVersion
            && lhs.disappearingSeconds == rhs.disappearingSeconds
    }
}

nonisolated struct UpdateConversationRequest: Encodable, Sendable {
    let title: String?
    let disappearingSeconds: Int?
    /// Absent, explicit-null and "clear" are three different intents server-side,
    /// which is why the clear is its own flag rather than an overloaded optional.
    let clearDisappearing: Bool?
    let mutedUntil: Date?
}

/// §4.4's probe. **Identical shape for every refusal** — a `can-message` that
/// distinguished "blocked" from "closed inbox" would be a block-detection oracle and
/// would defeat the 404 the create path is careful to return. Do not add a reason
/// field, and do not infer one from the status code.
nonisolated struct CanMessageResponse: Decodable, Sendable {
    let canMessage: Bool
    let existingConversationId: UUID?
}

// MARK: - Messages

nonisolated struct SendMessageRequest: Encodable, Sendable {
    let encryptedContent: String
    let contentType: String
    /// The offline-outbox idempotency key. A retry carries the SAME value and the
    /// server returns the original row rather than 409ing, so a retry can never
    /// double-send even when the first response was lost.
    let clientMessageId: UUID
    let senderDeviceId: UUID
    let groupKeyVersion: Int?
    let isQuantumSecure: Bool?
    let replyToId: UUID?
    let mediaObjectKey: String?
    let mediaThumbKey: String?
    let mediaMetadata: MessageMediaMetadata?
    let expiresAt: Date?
    /// One wrapped copy of the per-message key **per recipient device**, created
    /// eagerly at send. Empty for a group message — the devices already hold the
    /// group key at `groupKeyVersion`.
    let recipientKeys: [RecipientKey]

    nonisolated struct RecipientKey: Encodable, Sendable {
        let deviceId: UUID
        /// fwb-server requires the owning user id alongside the device id; Cove's
        /// DTO carried only the device. Missing it is a decode failure on send.
        let userId: UUID
        let encryptedMessageKey: String
        let isQuantumSecure: Bool?
    }
}

nonisolated struct MessageMediaMetadata: Codable, Sendable, Equatable {
    var width: Int?
    var height: Int?
    var durationSeconds: Double?
    var byteSize: Int?
    var mimeType: String?
}

nonisolated struct ChatMessageDTO: Decodable, Sendable, Identifiable, Equatable {
    let id: UUID
    let conversationId: UUID
    let senderId: UUID
    let senderDeviceId: UUID
    let encryptedContent: String
    let contentType: String
    let mediaObjectKey: String?
    let mediaThumbKey: String?
    let mediaMetadata: MessageMediaMetadata?
    let replyToId: UUID?
    let groupKeyVersion: Int?
    let isQuantumSecure: Bool
    let clientMessageId: UUID
    let expiresAt: Date?
    let editedAt: Date?
    let createdAt: Date?
    /// THIS device's wrapped copy of the key, when the request named a device.
    /// **Nil is normal, not an error**: history that predates a newly approved
    /// device has no wrapped key for it until A2's handoff runs (§4.3.3(B)).
    let encryptedMessageKey: String?
    let deliveredCount: Int
    let readCount: Int
    let reactions: [ReactionSummary]

    nonisolated struct ReactionSummary: Decodable, Sendable, Equatable {
        let emoji: String
        let userIds: [UUID]
    }

    static func == (lhs: ChatMessageDTO, rhs: ChatMessageDTO) -> Bool { lhs.id == rhs.id }
}

nonisolated struct MessagePageResponse: Decodable, Sendable {
    let items: [ChatMessageDTO]
    let hasMore: Bool
    let nextBefore: Date?
}

nonisolated struct MarkSeenRequest: Encodable, Sendable {
    let lastReadMessageId: UUID
}

nonisolated struct UnreadCountResponse: Decodable, Sendable {
    let total: Int
}

nonisolated struct ReactToMessageRequest: Encodable, Sendable {
    let emoji: String
}

// MARK: - Group keys

nonisolated struct UploadGroupKeysRequest: Encodable, Sendable {
    let keyVersion: Int
    let keys: [GroupKeyEntry]

    nonisolated struct GroupKeyEntry: Encodable, Sendable {
        let deviceId: UUID
        let encryptedGroupKey: String
    }
}

nonisolated struct GroupKeyDTO: Decodable, Sendable {
    let conversationId: UUID
    let keyVersion: Int
    let encryptedGroupKey: String
    let createdAt: Date?
}

// MARK: - A2 history handoff

nonisolated struct StartHandoffRequest: Encodable, Sendable {
    let sourceDeviceId: UUID
    let targetDeviceId: UUID
}

nonisolated struct HandoffStatusResponse: Decodable, Sendable {
    let id: UUID
    let sourceDeviceId: UUID
    let targetDeviceId: UUID
    let status: String
    let totalMessages: Int
    let deliveredMessages: Int
    let lastMessageAt: Date?
    let completedAt: Date?

    var isTerminal: Bool { status == "completed" || status == "cancelled" }

    var fraction: Double {
        guard totalMessages > 0 else { return status == "completed" ? 1 : 0 }
        return min(1, Double(deliveredMessages) / Double(totalMessages))
    }
}

nonisolated struct HandoffBatchRequest: Encodable, Sendable {
    let handoffId: UUID
    let keys: [WrappedKey]

    nonisolated struct WrappedKey: Encodable, Sendable {
        let messageId: UUID
        let encryptedMessageKey: String
        let isQuantumSecure: Bool?
    }
}

nonisolated struct HandoffPendingResponse: Decodable, Sendable {
    let handoffId: UUID
    let messageIds: [UUID]
    let hasMore: Bool
    let nextBefore: Date?
}

// MARK: - Media

nonisolated struct MediaUploadURLRequest: Encodable, Sendable {
    let contentType: String
    /// The CIPHERTEXT size — that is what R2 stores and what the 100 MB cap applies
    /// to.
    let byteSize: Int
    let needsThumbnail: Bool
}

nonisolated struct MediaUploadURLResponse: Decodable, Sendable {
    let objectKey: String
    let uploadUrl: String
    let thumbObjectKey: String?
    let thumbUploadUrl: String?
    let expiresInSeconds: Int
}

nonisolated struct MediaDownloadURLResponse: Decodable, Sendable {
    let objectKey: String
    let downloadUrl: String
    let thumbDownloadUrl: String?
    let expiresInSeconds: Int
}

// MARK: - Friends

nonisolated struct SendFriendRequestBody: Encodable, Sendable {
    let toUserId: UUID
    /// `friend_code | event | forum_profile`. Load-bearing: a `forum_profile`
    /// request is refused (as a 404, never a 403) when the recipient has turned
    /// `allow_forum_friend_requests` off — commissioner decision 9.
    let source: String
    let eventId: String?
}

nonisolated struct FriendRequestDTO: Decodable, Sendable, Identifiable, Equatable {
    let id: UUID
    let fromUserId: UUID
    let toUserId: UUID
    let status: String
    let context: String
    let fromDisplayName: String?
    let toDisplayName: String?
    let createdAt: Date?
    let respondedAt: Date?

    static func == (lhs: FriendRequestDTO, rhs: FriendRequestDTO) -> Bool {
        lhs.id == rhs.id && lhs.status == rhs.status
    }
}

nonisolated struct FriendDTO: Decodable, Sendable, Identifiable, Equatable {
    var id: UUID { userId }
    let userId: UUID
    let displayName: String
    let username: String?
    let avatarUrl: String?
    let source: String
    let friendsSince: Date?

    static func == (lhs: FriendDTO, rhs: FriendDTO) -> Bool { lhs.userId == rhs.userId }
}

nonisolated struct FriendCodeLookupResponse: Decodable, Sendable {
    let userId: UUID
    let displayName: String
    let username: String?
    let avatarUrl: String?
    let acceptsFriendRequests: Bool
}

// MARK: - WebSocket frames

/// The frame envelope. The server encodes with the global snake_case encoder, so
/// `conversationId` arrives as `conversation_id`.
///
/// The payload is deliberately decoded lazily: `message` frames carry a whole
/// `ChatMessageDTO`, while every other type carries a small string dictionary. One
/// enum with an associated value per case would need the frame type before the
/// payload, which is exactly the ordering `Codable` does not give us.
nonisolated struct ChatWSFrame: Decodable, Sendable {
    let type: String
    let conversationId: UUID?
    let senderId: UUID?
    let timestamp: Date

    /// `message` frames only.
    let message: ChatMessageDTO?
    /// Every other frame type: a flat `[String: String]` payload.
    let values: [String: String]

    private enum CodingKeys: String, CodingKey {
        case type, conversationId, senderId, timestamp, payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        conversationId = try container.decodeIfPresent(UUID.self, forKey: .conversationId)
        senderId = try container.decodeIfPresent(UUID.self, forKey: .senderId)
        timestamp = (try? container.decode(Date.self, forKey: .timestamp)) ?? Date()

        if type == ChatWSType.message {
            message = try? container.decode(ChatMessageDTO.self, forKey: .payload)
            values = [:]
        } else {
            message = nil
            // Tolerant: a typing frame's payload is `{"is_typing": true}` (a Bool),
            // while read/reaction payloads are strings. Decode both into strings so
            // one shape can carry every ephemeral signal.
            values = (try? container.decode(LenientStringDictionary.self, forKey: .payload))?.values ?? [:]
        }
    }
}

/// Decodes a flat JSON object into `[String: String]`, coercing bools and numbers.
/// The server's ephemeral payloads mix `{"is_typing": true}` with
/// `{"message_id": "…"}`, and a strict `[String: String]` would drop the first.
private nonisolated struct LenientStringDictionary: Decodable {
    let values: [String: String]

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        var out: [String: String] = [:]
        for key in container.allKeys {
            if let string = try? container.decode(String.self, forKey: key) {
                out[key.stringValue] = string
            } else if let bool = try? container.decode(Bool.self, forKey: key) {
                out[key.stringValue] = bool ? "true" : "false"
            } else if let number = try? container.decode(Int.self, forKey: key) {
                out[key.stringValue] = String(number)
            }
        }
        values = out
    }
}

/// Outbound frames. The socket accepts a deliberately short list — anything that
/// mutates durable state has a REST route, and a socket frame that could write would
/// be a second, unauthenticated-by-habit write path.
nonisolated struct OutboundWSFrame: Encodable, Sendable {
    let type: String
    let conversationId: UUID?
    let messageId: UUID?
    let isTyping: Bool?

    static func typing(_ conversationId: UUID, isTyping: Bool) -> OutboundWSFrame {
        OutboundWSFrame(type: ChatWSType.typing, conversationId: conversationId, messageId: nil, isTyping: isTyping)
    }

    static func delivered(_ conversationId: UUID, messageId: UUID) -> OutboundWSFrame {
        OutboundWSFrame(type: ChatWSType.delivered, conversationId: conversationId, messageId: messageId, isTyping: nil)
    }

    static let ping = OutboundWSFrame(type: "ping", conversationId: nil, messageId: nil, isTyping: nil)
}

nonisolated enum ChatWSType {
    static let message = "message"
    static let typing = "typing"
    static let read = "read"
    static let delivered = "delivered"
    static let reaction = "reaction"
    static let edited = "edited"
    static let deleted = "deleted"
    static let deviceAdded = "device_added"
    static let deviceRevoked = "device_revoked"
    static let handoffProgress = "handoff_progress"
}
