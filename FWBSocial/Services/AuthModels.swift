import Foundation

// MARK: - Authenticated user
//
// Trimmed relative to Flux's `AuthUser`: FWB has no creator/host role, just
// member vs. admin/moderator (PLAN.md §2.1's `is_admin` / `is_moderator`).
// `vettingState` mirrors `fwb_users.vetting_state`, which gates most of the app
// (§4.6) — modeled here as a hint the way `AuthPayload.vetted` is server-side;
// callers should treat `RequireVettedMember`-guarded routes as the source of truth.

nonisolated struct AuthUser: Codable, Sendable, Identifiable, Equatable, Hashable {
    let id: String
    let email: String
    let displayName: String
    var avatarUrl: String?
    var emailVerified: Bool
    var isAdmin: Bool
    var isModerator: Bool
    var vettingState: String?

    var isVetted: Bool { vettingState == "vetted" }
}

/// The login/register/refresh envelope: `{ user, token, refreshToken }`.
nonisolated struct AuthTokenResponse: Decodable, Sendable {
    let user: AuthUser?
    let token: String?
    let refreshToken: String?

    // Some auth endpoints (e.g. refresh) return `access_token`; accept both.
    let accessToken: String?

    var resolvedAccessToken: String? { token ?? accessToken }
}
