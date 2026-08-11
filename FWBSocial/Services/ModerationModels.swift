import Foundation

// MARK: - Moderation wire models
//
// Mirrors fwb-server's `ModerationDTOs.swift` and the enums in
// `ModerationModels.swift`. Same two wire rules as everywhere else: no explicit
// CodingKeys, no consecutive capitals.
//
// Phase 5's endpoints are live, so report and block ship with the forum rather
// than trailing it. Guideline 1.2 wants a report affordance on *every* UGC
// surface, and a surface that ships without one is exactly how that rejection
// happens.

// MARK: - Report reasons

/// Mirrors the server's `ReportReason`. The raw values are the wire tokens and
/// the server rejects anything outside the set, so these strings are load-bearing
/// — `sexual_content`, not `sexualContent`.
nonisolated enum ReportReason: String, CaseIterable, Sendable, Identifiable {
    case harassment
    case sexualContent = "sexual_content"
    case violence
    case hateSpeech = "hate_speech"
    case spam
    case impersonation
    case selfHarm = "self_harm"
    case underage
    case other

    nonisolated var id: String { rawValue }

    var label: String {
        switch self {
        case .harassment:     return "Harassment or bullying"
        case .sexualContent:  return "Sexual content"
        case .violence:       return "Violence or threats"
        case .hateSpeech:     return "Hate speech"
        case .spam:           return "Spam"
        case .impersonation:  return "Impersonation"
        case .selfHarm:       return "Self-harm"
        case .underage:       return "Underage member"
        case .other:          return "Something else"
        }
    }

    var systemImage: String {
        switch self {
        case .harassment:     return "person.fill.xmark"
        case .sexualContent:  return "eye.slash"
        case .violence:       return "exclamationmark.triangle"
        case .hateSpeech:     return "quote.bubble"
        case .spam:           return "tray.full"
        case .impersonation:  return "person.crop.circle.badge.questionmark"
        case .selfHarm:       return "heart.slash"
        case .underage:       return "figure.child"
        case .other:          return "ellipsis.circle"
        }
    }
}

/// Mirrors the server's `ReportTargetType`. `chat_message` exists on the wire but
/// is unreachable until Phase 6 — a chat report must carry an evidence bundle the
/// server cannot assemble itself, and there is no chat client yet.
nonisolated enum ReportTargetType: String, Sendable {
    case post
    case comment
    case announcement
    case user
    case chatMessage = "chat_message"

    var subjectNoun: String {
        switch self {
        case .post:         return "post"
        case .comment:      return "comment"
        case .announcement: return "announcement"
        case .user:         return "member"
        case .chatMessage:  return "message"
        }
    }
}

// MARK: - Reports

nonisolated struct CreateReportRequest: Encodable, Sendable {
    let targetType: String
    let targetId: String
    let reason: String
    var details: String?
    // `evidence` is deliberately absent: it is only for `chat_message`, which
    // Phase 4 cannot produce. Adding the field here as a permanent nil would
    // imply this client can attest chat plaintext, which it cannot.
}

nonisolated struct ReportResponse: Decodable, Sendable, Identifiable, Equatable {
    let id: String
    let targetType: String?
    let targetId: String?
    let targetAuthorId: String?
    let reason: String?
    let details: String?
    /// `open` | `triaging` | `actioned` | `dismissed`.
    let status: String?
    let assignedTo: String?
    let resolution: String?
    let resolutionNote: String?
    let createdAt: Date?
    let resolvedAt: Date?

    /// Surfaced on every row so the 24-hour SLA needs no arithmetic client-side.
    let ageHours: Double?
    /// True past the SLA and still unresolved — the server's call, not a
    /// threshold this client re-derives.
    let breachesSla: Bool?
    let hasEvidence: Bool?
    let reporterDisplayName: String?
    let targetAuthorDisplayName: String?

    var isOpen: Bool { status == "open" }
    var isTriaging: Bool { status == "triaging" }
    var isResolved: Bool { status == "actioned" || status == "dismissed" }
    var breaching: Bool { breachesSla ?? false }
    var reasonLabel: String { ReportReason(rawValue: reason ?? "")?.label ?? (reason ?? "Reported") }
    var targetNoun: String { ReportTargetType(rawValue: targetType ?? "")?.subjectNoun ?? "item" }

    /// A system auto-flag from the blocked-terms filter has no human reporter.
    var isSystemFlag: Bool { reporterDisplayName == "system" }

    var ageLabel: String {
        guard let ageHours else { return "" }
        if ageHours < 1 { return "\(Int(ageHours * 60))m" }
        if ageHours < 24 { return "\(Int(ageHours))h" }
        return "\(Int(ageHours / 24))d"
    }
}

nonisolated struct ReportQueueResponse: Decodable, Sendable {
    let items: [ReportResponse]
    let total: Int?
    let openCount: Int?
    let triagingCount: Int?
    let oldestOpenAgeHours: Double?
    let slaBreachCount: Int?
}

/// Mirrors the server's `ModerationOutcome`.
nonisolated enum ModerationOutcome: String, CaseIterable, Sendable, Identifiable {
    case noAction = "no_action"
    case contentRemoved = "content_removed"
    case warned
    case vettingRevoked = "vetting_revoked"
    case banned

    nonisolated var id: String { rawValue }

    var label: String {
        switch self {
        case .noAction:       return "No action needed"
        case .contentRemoved: return "Content removed"
        case .warned:         return "Member warned"
        case .vettingRevoked: return "Vetting revoked"
        case .banned:         return "Member banned"
        }
    }

    /// `no_action` closes a report as `dismissed`; everything else is `actioned`.
    /// The server takes the status explicitly rather than inferring it, so this
    /// mapping lives on the client that made the choice.
    var reportStatus: String { self == .noAction ? "dismissed" : "actioned" }
}

nonisolated struct ResolveReportRequest: Encodable, Sendable {
    let resolution: String
    var note: String?
    var status: String?
}

nonisolated struct AssignReportRequest: Encodable, Sendable {
    /// nil hands it back to the unassigned pool.
    var assigneeId: String?
}

// MARK: - Blocks

nonisolated struct BlockedUserResponse: Decodable, Sendable, Identifiable, Equatable {
    let userId: String
    let displayName: String?
    let username: String?
    let blockedAt: Date?

    nonisolated var id: String { userId }
    var name: String { displayName ?? "Member" }
}
