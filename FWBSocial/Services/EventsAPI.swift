import Foundation

// MARK: - Events wire models
//
// Mirrors fwb-server's `EventWindowController` DTOs and `LumaEmailController`'s.
// Same two wire rules as everywhere else: no explicit snake_case `CodingKeys`, and
// no consecutive capitals (`lumaEventId`, never `lumaEventID`).
//
// Note what the roster DTO does NOT carry: no email, no `luma_guest_id`, no
// `luma_user_id`, no check-in timestamp. Those are absent server-side by
// construction rather than filtered, and the client has no business reconstructing
// them — a roster is "who else was here", not an attendance log.

nonisolated struct FriendingWindowDTO: Decodable, Sendable, Identifiable {
    var id: String { lumaEventId }
    let lumaEventId: String
    let eventName: String
    let endedAt: Date?
    let opensAt: Date?
    let closesAt: Date?
    /// Countdown material from the SERVER's clock. Rendered as given rather than
    /// recomputed from `closesAt` against the device clock, which can be wrong —
    /// and a countdown that disagrees with the server about whether the window is
    /// still open is worse than no countdown.
    let secondsRemaining: Int
    let attendeeCount: Int
}

nonisolated struct EventAttendeeDTO: Decodable, Sendable, Identifiable {
    var id: UUID { userId }
    let userId: UUID
    let displayName: String
    let username: String?
    let avatarUrl: String?
    let bio: String?
    let isFriend: Bool
    /// `none` · `outgoing` · `incoming`.
    let requestState: String

    var state: RequestState {
        if isFriend { return .friends }
        return RequestState(rawValue: requestState) ?? .none
    }

    nonisolated enum RequestState: String, Sendable {
        case none
        case outgoing
        case incoming
        case friends
    }
}

nonisolated struct LumaEmailStatusDTO: Decodable, Sendable {
    let lumaEmail: String?
    let verified: Bool
    /// True when the account's own address cannot appear on a guest list — a
    /// `@privaterelay.appleid.com` relay address. The prompt becomes
    /// mandatory-with-explanation rather than a dismissible card (§4.5.3): under
    /// pure email matching, every privacy-conscious Sign in with Apple member is
    /// unvettable, and SIWA is not optional.
    let promptRequired: Bool
    let vettingState: String
}

// MARK: - API

@MainActor
enum EventsAPI {

    private static var api: APIClient { APIClient.shared }

    /// `GET /api/events/windows` — the caller's currently OPEN windows.
    ///
    /// There is deliberately no "list all events" route to fall back on: a roster
    /// the caller did not attend is not theirs to see, and an event list would be
    /// the beginning of one.
    static func openWindows() async throws -> [FriendingWindowDTO] {
        try await api.get("/api/events/windows")
    }

    /// `GET /api/events/:lumaEventId/attendees`
    ///
    /// A 404 covers three different refusals — no such event, window not open, you
    /// weren't there — and the client must not try to tell them apart. Rendering a
    /// single "this window has closed" state for all three is the correct
    /// behaviour, not a shortcut.
    static func attendees(lumaEventId: String) async throws -> [EventAttendeeDTO] {
        let encoded = lumaEventId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? lumaEventId
        return try await api.get("/api/events/\(encoded)/attendees")
    }

    // MARK: - Luma email linking

    static func lumaEmailStatus() async throws -> LumaEmailStatusDTO {
        try await api.get("/api/luma/email")
    }

    private struct RequestCodeBody: Encodable { let email: String }
    private struct VerifyBody: Encodable { let email: String; let code: String }

    /// Sends a six-digit code to the address **the member typed into this app**.
    ///
    /// This is the only address the system ever mails. `fwb_luma_guests.email` is
    /// match-only and no code path may reach the mailer with it — that is a Luma
    /// ToS boundary (PLAN.md R13), and emailing guests who never consented can
    /// suspend the calendar's Plus account.
    static func requestLumaEmailCode(_ email: String) async throws {
        try await api.postVoid("/api/luma/email/request-code", body: RequestCodeBody(email: email))
    }

    static func verifyLumaEmail(_ email: String, code: String) async throws -> LumaEmailStatusDTO {
        try await api.post("/api/luma/email/verify", body: VerifyBody(email: email, code: code))
    }
}
