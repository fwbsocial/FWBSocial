import Foundation

// MARK: - Domain models
//
// The view layer never touches a DTO. Cove's `Message` carried both the ciphertext
// and the decrypted text; this keeps that shape, because the bubble reads
// `decryptedText` and nothing else, and the media path still needs `mediaObjectKey`
// to fetch and decrypt.

nonisolated struct ChatMessage: Identifiable, Sendable, Equatable {

    enum ContentType: String, Sendable {
        case text
        case image
        case video
        case audio
        case file
        case system

        var phrase: String {
            switch self {
            case .text: return "sent a message"
            case .image: return "sent a photo"
            case .video: return "sent a video"
            case .audio: return "sent a voice message"
            case .file: return "sent a file"
            case .system: return "updated the conversation"
            }
        }
    }

    /// Where a message is in its delivery lifecycle. `pending` and `failed` only
    /// ever apply to the local optimistic copy — the server has no such states.
    enum SendState: Sendable, Equatable {
        case sent
        case pending
        case failed
    }

    let id: UUID
    let conversationId: UUID
    let senderId: UUID
    let senderDeviceId: UUID
    let clientMessageId: UUID
    let contentType: ContentType
    let createdAt: Date
    let expiresAt: Date?
    let editedAt: Date?
    let replyToId: UUID?
    let groupKeyVersion: Int?
    let isQuantumSecure: Bool

    let mediaObjectKey: String?
    let mediaThumbKey: String?
    let mediaMetadata: MessageMediaMetadata?

    /// Nil means this device could not open it. Two very different causes, and the
    /// UI distinguishes them: `hasKeyForThisDevice == false` is "this device wasn't
    /// around when it was sent" (§4.3.3(B) — normal, fixed by A2's handoff), while a
    /// present key that failed to open is a real decryption failure.
    var decryptedText: String?
    var hasKeyForThisDevice: Bool

    var deliveredCount: Int
    var readCount: Int
    var reactions: [String: [UUID]]
    var sendState: SendState

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }

    /// What to render when there is no plaintext. Never blank — a blank bubble reads
    /// as a broken app, and the honest sentence is short.
    var placeholderText: String {
        hasKeyForThisDevice
            ? "Couldn't decrypt this message"
            : "Sent before this device was added"
    }

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id
            && lhs.decryptedText == rhs.decryptedText
            && lhs.deliveredCount == rhs.deliveredCount
            && lhs.readCount == rhs.readCount
            && lhs.reactions == rhs.reactions
            && lhs.sendState == rhs.sendState
            && lhs.editedAt == rhs.editedAt
    }
}

extension ChatMessage {
    init(dto: ChatMessageDTO, decrypted: String?, hasKey: Bool) {
        id = dto.id
        conversationId = dto.conversationId
        senderId = dto.senderId
        senderDeviceId = dto.senderDeviceId
        clientMessageId = dto.clientMessageId
        contentType = ContentType(rawValue: dto.contentType) ?? .text
        createdAt = dto.createdAt ?? Date()
        expiresAt = dto.expiresAt
        editedAt = dto.editedAt
        replyToId = dto.replyToId
        groupKeyVersion = dto.groupKeyVersion
        isQuantumSecure = dto.isQuantumSecure
        mediaObjectKey = dto.mediaObjectKey
        mediaThumbKey = dto.mediaThumbKey
        mediaMetadata = dto.mediaMetadata
        decryptedText = decrypted
        hasKeyForThisDevice = hasKey
        deliveredCount = dto.deliveredCount
        readCount = dto.readCount
        reactions = Dictionary(uniqueKeysWithValues: dto.reactions.map { ($0.emoji, $0.userIds) })
        sendState = .sent
    }
}

// MARK: - Conversation

nonisolated struct ChatConversation: Identifiable, Sendable, Equatable {
    let id: UUID
    let isGroup: Bool
    var title: String?
    var avatarUrl: String?
    let createdBy: UUID?
    var requireQuantum: Bool
    var groupKeyVersion: Int
    var disappearingSeconds: Int?
    var lastMessageAt: Date?
    var memberIds: [UUID]
    var unreadCount: Int
    var muted: Bool
    let createdAt: Date?

    /// The other participant of a 1:1. Nil for a group, and nil for the degenerate
    /// self-conversation that shouldn't exist but shouldn't crash either.
    func otherMemberId(me: UUID) -> UUID? {
        guard !isGroup else { return nil }
        return memberIds.first { $0 != me }
    }

    static func == (lhs: ChatConversation, rhs: ChatConversation) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.lastMessageAt == rhs.lastMessageAt
            && lhs.unreadCount == rhs.unreadCount
            && lhs.muted == rhs.muted
            && lhs.memberIds == rhs.memberIds
            && lhs.groupKeyVersion == rhs.groupKeyVersion
            && lhs.disappearingSeconds == rhs.disappearingSeconds
    }
}

extension ChatConversation {
    init(dto: ConversationDTO) {
        id = dto.id
        isGroup = dto.isGroup
        title = dto.title
        avatarUrl = dto.avatarUrl
        createdBy = dto.createdBy
        requireQuantum = dto.requireQuantum
        groupKeyVersion = dto.currentGroupKeyVersion
        disappearingSeconds = dto.disappearingSeconds
        lastMessageAt = dto.lastMessageAt
        memberIds = dto.memberIds
        unreadCount = dto.unreadCount
        muted = dto.muted
        createdAt = dto.createdAt
    }
}

// MARK: - Message TTL
//
// PLAN.md §2.8 and commissioner decision 10: the server default is 365 days, and
// "off" is available but must never be the default — it makes storage unbounded on a
// single small machine, and an indefinite ciphertext archive is also the weaker
// security posture.

nonisolated enum MessageTTL: Int, CaseIterable, Identifiable, Sendable {
    case thirtyDays = 30
    case ninetyDays = 90
    case oneYear = 365
    case off = 0

    var id: Int { rawValue }

    var seconds: Int? { self == .off ? nil : rawValue * 86_400 }

    var label: String {
        switch self {
        case .thirtyDays: return "30 days"
        case .ninetyDays: return "90 days"
        case .oneYear:    return "1 year"
        case .off:        return "Off"
        }
    }

    static func from(seconds: Int?) -> MessageTTL {
        guard let seconds, seconds > 0 else { return .off }
        let days = seconds / 86_400
        return MessageTTL(rawValue: days) ?? .oneYear
    }
}

// MARK: - Inbox policy
//
// §4.4. Metadata the server owns — E2EE does not touch this — enforced at
// conversation create and add-member.

nonisolated enum InboxPolicy: String, CaseIterable, Identifiable, Sendable {
    case open
    case friendsOnly = "friends_only"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .open:        return "Anyone"
        case .friendsOnly: return "Friends only"
        }
    }

    var explanation: String {
        switch self {
        case .open:
            return "Any vetted member can start a conversation with you."
        case .friendsOnly:
            return "Only people you've friended can start a conversation with you. Existing conversations aren't affected."
        }
    }
}
