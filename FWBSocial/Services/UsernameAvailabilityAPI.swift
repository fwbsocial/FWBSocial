import Foundation

// MARK: - Username availability
//
// `GET /api/auth/username-availability?u=<candidate>` — authenticated, rate
// limited 30/min (fwb-server `routes.swift`, bucket `username-availability`).
//
// The answer is deliberately machine-readable. `status` says what happened and
// `code` says which rule was broken, so the client never has to match on the
// English in `reason` — the server owns that sentence, the client owns the icon
// and the disabled state.
//
//   { "status": "available" | "taken" | "invalid" | "current",
//     "username": "<canonical>",       // trimmed + lowercased; what WOULD be stored
//     "available": true | false,
//     "reason":   "Periods can't start, end, or repeat",   // present when refused
//     "code":     "bad_periods" }                          // present when refused
//
// `current` is the member's own handle: neither taken nor a change. It is a
// neutral state, not an error.

/// The server's verdict. Unknown values decode to `nil` rather than throwing —
/// a status this build has never heard of must not break the field.
nonisolated enum UsernameStatus: String, Sendable, Equatable {
    case available
    case taken
    case invalid
    case current
}

/// Which rule was broken. Mirrors `UsernameRules.Verdict.code` on the server.
nonisolated enum UsernameRuleCode: String, Sendable, Equatable {
    case tooShort = "too_short"
    case tooLong = "too_long"
    case badCharacters = "bad_characters"
    case badPeriods = "bad_periods"
    case noAlphanumeric = "no_alphanumeric"
    case reserved
    case taken

    /// A local sentence for the rule, used only when the server sent a `code`
    /// with no `reason`. The server's `reason` is preferred whenever it exists —
    /// it is the authoritative wording and it moves with the rules.
    var fallbackMessage: String {
        switch self {
        case .tooShort:        "Usernames must be at least 3 characters"
        case .tooLong:         "Usernames can be at most 30 characters"
        case .badCharacters:   "Use only letters, numbers, underscores and periods"
        case .badPeriods:      "Periods can't start, end, or repeat"
        case .noAlphanumeric:  "Usernames need at least one letter or number"
        case .reserved:        "That username isn't available"
        case .taken:           "That username is taken"
        }
    }
}

nonisolated struct UsernameAvailabilityDTO: Decodable, Sendable, Equatable {
    let status: String
    /// The canonical form — trimmed and lowercased. This is what the server
    /// would store, so it is what the field previews back to the member.
    let username: String
    let available: Bool
    let reason: String?
    let code: String?

    var parsedStatus: UsernameStatus? { UsernameStatus(rawValue: status) }
    var parsedCode: UsernameRuleCode? { code.flatMap(UsernameRuleCode.init(rawValue:)) }

    /// What to show under the field when the candidate was refused.
    var refusalMessage: String? {
        reason ?? parsedCode?.fallbackMessage
    }
}

extension APIClient {
    /// Live availability for a candidate handle. Send it raw — canonicalisation
    /// is the server's job, and its echo is what the member is shown.
    func usernameAvailability(_ candidate: String) async throws -> UsernameAvailabilityDTO {
        try await get(APIClient.path("/api/auth/username-availability", query: ["u": candidate]))
    }
}
