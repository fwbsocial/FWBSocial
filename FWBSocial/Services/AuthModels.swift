import Foundation

// MARK: - Authenticated user
//
// A field-for-field mirror of fwb-server's `UserResponse` (Sources/App/Auth/AuthDTOs.swift),
// whose emitted snake_case keys are pinned by the server's `WireContractTests`
// (`testUserResponseEmitsTheExpectedSnakeCaseKeys`). Both sides decode with
// `.convertFromSnakeCase`, so these property names ARE the contract.
//
// **No consecutive capitals, ever.** Foundation's snake_case conversion is not
// symmetric across them: `notifyDM` encodes to `notify_dm` but `notify_dm`
// decodes to `notifyDm`, so the field silently fails to decode on this side
// while the server looks healthy. Write `avatarUrl`, `notifyDm`, `lumaEmail`.
//
// Non-optional only where the server can never omit the key. Everything the
// server models as nullable is Optional here — a wire-nullable field typed
// non-optional throws `valueNotFound` and takes the whole response down with it.

nonisolated struct AuthUser: Codable, Sendable, Identifiable, Equatable, Hashable {
    let id: String
    let email: String
    var displayName: String
    var username: String?
    var avatarUrl: String?
    var bio: String?
    var friendCode: String?
    var emailVerified: Bool

    /// A SIWA-only account has no password rather than an unknowable one — this
    /// is what decides whether "Change password" is offered at all.
    var hasPassword: Bool?
    var hasAppleSignIn: Bool?

    /// `pending` | `vetted` | `rejected` | `revoked` (PLAN.md §2.1). A **hint**:
    /// the server's `RequireVettedMember` always re-reads the row, so never gate
    /// anything security-relevant on this alone — only what the UI shows.
    var vettingState: String?
    var vettingSource: String?
    var vettedAt: Date?

    // Privacy (PLAN.md §2.1)
    var inboxPolicy: String?
    var isDiscoverable: Bool?
    var hideMessagePreviews: Bool?

    // Luma linkage (PLAN.md §4.5.3)
    var lumaEmail: String?
    var lumaEmailVerified: Bool?

    // Moderation
    var isAdmin: Bool
    var isModerator: Bool

    // Notification preferences
    var notifyAnnouncements: Bool?
    var notifyDm: Bool?
    var notifyFriendRequests: Bool?
    var notifyChannelPosts: Bool?

    var timezone: String?
    var lastActiveAt: Date?
    var createdAt: Date?
    var updatedAt: Date?

    var isVetted: Bool { vettingState == "vetted" }

    /// Human-readable vetting status for the profile/status card.
    var vettingLabel: String {
        switch vettingState {
        case "vetted":   return "Vetted"
        case "rejected": return "Not approved"
        case "revoked":  return "Access removed"
        default:         return "Pending"
        }
    }
}

/// fwb-server's `AuthResponse`: `{ user, access_token, refresh_token }`.
///
/// `user` is non-optional server-side; it stays Optional here so a future
/// token-only response (or a partial rollout) degrades to a `/me` fetch instead
/// of failing the sign-in outright. `token` is accepted as an alias because the
/// ported Flux kit emitted that name and a stale server would otherwise look
/// like a silent auth failure.
nonisolated struct AuthTokenResponse: Decodable, Sendable {
    let user: AuthUser?
    let token: String?
    let refreshToken: String?
    let accessToken: String?

    var resolvedAccessToken: String? { accessToken ?? token }
}

/// `{ message: String }` — fwb-server's `StatusMessageResponse`.
nonisolated struct StatusMessageResponse: Decodable, Sendable {
    let message: String
}
