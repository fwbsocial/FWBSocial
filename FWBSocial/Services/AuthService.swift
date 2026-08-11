import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: "events.fwb.social", category: "Auth")

// MARK: - Auth errors

enum AuthError: LocalizedError {
    case invalidCredentials
    case message(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials: return "That email or password didn't match."
        case .message(let m): return m
        }
    }
}

// MARK: - Auth service
//
// Ported from Flux's `AuthService` (PLAN.md §5.2 / §3), then aligned field by
// field against the deployed fwb-server contract (`Sources/App/Auth/AuthDTOs.swift`
// + `routes.swift`). Stripped: two-factor auth (dropped for v1 — device approval
// is FWB's second factor, PLAN.md §3) and Flux's event-password plumbing.
//
// Routes, as deployed:
//   POST   /api/auth/register | login | apple | refresh
//   POST   /api/auth/forgot-password | reset-password | verify-email
//   GET    /api/auth/me
//   POST   /api/auth/logout | change-password | resend-verification | avatar
//   PUT    /api/auth/profile
//   DELETE /api/auth/account

@Observable
@MainActor
final class AuthService {

    static let shared = AuthService()

    /// The signed-in user, or `nil` when signed out.
    private(set) var user: AuthUser?

    /// True once the initial session-restore attempt has completed. The root
    /// view holds a splash until this flips, so a returning member never sees a
    /// signed-out flash.
    private(set) var didRestoreSession = false

    var isSignedIn: Bool { user != nil }
    var isAdmin: Bool { user?.isAdmin ?? false }
    var isModerator: Bool { user?.isModerator ?? false }

    private let api = APIClient.shared

    private init() {}

    // MARK: - Session restore

    /// Restore the session at launch: if a token is stored, fetch `/me`.
    func restoreSession() async {
        defer { didRestoreSession = true }
        guard api.accessToken != nil else { return }
        do {
            user = try await fetchMe()
            PushCoordinator.shared.syncRegistration()
            await OnboardingService.shared.refresh(for: user)
        } catch APIError.unauthorized {
            // The refresh token is spent or revoked. Anything else (offline, 500)
            // leaves the tokens alone — a transient failure must not sign anyone out.
            logger.notice("Session restore rejected; signing out")
            signOut()
        } catch {
            logger.debug("Session restore failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Login / register

    private struct LoginBody: Encodable {
        let email: String
        let password: String
    }

    private struct RegisterBody: Encodable {
        let email: String
        let password: String
        let displayName: String
        let username: String?
    }

    /// The Sign in with Apple body. **`authorizationCode` is the whole point of
    /// this shape** (PLAN.md §3.1): the server exchanges it once, at sign-in
    /// time, for the refresh token that account deletion needs to revoke the
    /// Apple grant. The code is single-use and short-lived — drop it and every
    /// SIWA account becomes unrevocable, which surfaces at the first App Review
    /// deletion test.
    ///
    /// `fullName` is the server's field name (NOT `displayName`); it is used for
    /// the display name only. `email` is accepted and deliberately ignored by
    /// the server — it is attacker-controlled and never used to select a row.
    private struct AppleSignInBody: Encodable {
        let identityToken: String
        let authorizationCode: String?
        let fullName: String?
        let email: String?
    }

    func login(email: String, password: String) async throws {
        do {
            let resp: AuthTokenResponse = try await api.request(
                "POST", "/api/auth/login",
                body: try FWBJSON.encoder.encode(LoginBody(email: email, password: password)),
                retryOnUnauth: false)
            try await applyTokens(resp)
        } catch let APIError.httpError(code, message) {
            if code == 401 { throw AuthError.invalidCredentials }
            throw AuthError.message(message ?? "Sign in failed.")
        } catch APIError.unauthorized {
            throw AuthError.invalidCredentials
        }
    }

    func register(displayName: String, email: String, password: String, username: String? = nil) async throws {
        do {
            let resp: AuthTokenResponse = try await api.request(
                "POST", "/api/auth/register",
                body: try FWBJSON.encoder.encode(
                    RegisterBody(email: email, password: password,
                                 displayName: displayName, username: username)),
                retryOnUnauth: false)
            try await applyTokens(resp)
        } catch let APIError.httpError(_, message) {
            throw AuthError.message(message ?? "We couldn't create that account.")
        }
    }

    func appleSignIn(
        identityToken: String,
        authorizationCode: String?,
        fullName: String? = nil,
        email: String? = nil
    ) async throws {
        if authorizationCode == nil {
            // Not fatal on the wire (the server fails soft), but it means this
            // account can never have its Apple grant revoked at deletion.
            logger.error("SIWA credential had no authorizationCode — the Apple grant will be unrevocable for this account")
        }
        do {
            let resp: AuthTokenResponse = try await api.request(
                "POST", "/api/auth/apple",
                body: try FWBJSON.encoder.encode(
                    AppleSignInBody(identityToken: identityToken,
                                    authorizationCode: authorizationCode,
                                    fullName: fullName,
                                    email: email)),
                retryOnUnauth: false)
            try await applyTokens(resp)
        } catch let APIError.httpError(_, message) {
            throw AuthError.message(message ?? "Apple couldn't sign you in.")
        }
    }

    private func applyTokens(_ resp: AuthTokenResponse) async throws {
        guard let access = resp.resolvedAccessToken else {
            throw AuthError.message("The server didn't return a session token.")
        }
        api.accessToken = access
        if let refresh = resp.refreshToken { api.refreshToken = refresh }

        if let u = resp.user {
            user = u
        } else {
            user = try await fetchMe()
        }
        // Now signed in — flush any cached APNs token to the backend, and work
        // out whether onboarding still owes us anything.
        PushCoordinator.shared.syncRegistration()
        await OnboardingService.shared.refresh(for: user)
    }

    // MARK: - Refresh

    /// The single in-flight refresh, shared by all concurrent callers.
    ///
    /// When multiple views mount at once, their first fetches can 401
    /// simultaneously and each ask for a refresh. Without coalescing, N
    /// concurrent refreshes each read the SAME single-use refresh token from the
    /// Keychain and POST `/api/auth/refresh` — the server rotates the token on the
    /// first POST, so every later POST double-spends an already-consumed token
    /// and fails. Storing the Task here makes it single-flight.
    private var refreshTask: Task<Bool, Never>?

    @discardableResult
    func refresh() async -> Bool {
        if let existing = refreshTask {
            return await existing.value
        }
        let task = Task { () -> Bool in
            let ok = await self.performRefresh()
            self.refreshTask = nil
            return ok
        }
        refreshTask = task
        return await task.value
    }

    private func performRefresh() async -> Bool {
        guard let refreshToken = api.refreshToken else { return false }
        struct RefreshBody: Encodable { let refreshToken: String }
        do {
            let req = try FWBJSON.encoder.encode(RefreshBody(refreshToken: refreshToken))
            let resp: AuthTokenResponse = try await api.request("POST", "/api/auth/refresh", body: req, retryOnUnauth: false)
            guard let access = resp.resolvedAccessToken else { return false }
            api.accessToken = access
            if let r = resp.refreshToken { api.refreshToken = r }
            return true
        } catch {
            logger.warning("Token refresh failed: \(error.localizedDescription)")
            if case APIError.unauthorized = error { signOut() }
            if case APIError.httpError(let code, _) = error, code == 401 { signOut() }
            return false
        }
    }

    // MARK: - Me

    func fetchMe() async throws -> AuthUser {
        // `/me` returns the user object directly; the `{ user: ... }` wrapper is
        // tolerated so a server-side envelope change isn't a client outage.
        struct Wrapped: Decodable { let user: AuthUser }
        let data: Data = try await rawGet("/api/auth/me")
        if let u = try? FWBJSON.decoder.decode(AuthUser.self, from: data) { return u }
        return try FWBJSON.decoder.decode(Wrapped.self, from: data).user
    }

    /// Refresh the cached user from `/me`. Silently keeps the previous value on
    /// failure — a flaky network must not blank the profile.
    func reloadUser() async {
        if let fresh = try? await fetchMe() { user = fresh }
    }

    private func rawGet(_ path: String) async throws -> Data {
        var req = URLRequest(url: URL(string: api.baseURL + path)!)
        req.setValue(FWBConfig.appId, forHTTPHeaderField: "X-App-Id")
        if let token = api.accessToken { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 30
        let (bytes, response) = try await URLSession.shared.data(for: req)
        // 401 only — see the note in `APIClient.request`. A 403 from `/me`
        // would be a real authorization answer, not an expired session.
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            if await refresh() { return try await rawGet(path) }
            throw APIError.unauthorized
        }
        // A deleted account answers 404 here (the row is tombstoned, so
        // `req.liveUser()` finds nothing). That's a dead session, not a missing
        // endpoint: without this the tokens survive in the Keychain and every
        // launch re-attempts them.
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            throw APIError.unauthorized
        }
        return bytes
    }

    // MARK: - Profile

    /// Mirrors fwb-server's `UpdateProfileRequest`. Every field is Optional and
    /// omitted fields are left alone, so a caller changing one setting cannot
    /// accidentally reset the others.
    /// Defaults are `nil` throughout so a caller can name exactly the one field
    /// it means to change — `ProfileUpdate(notifyDm: false)` must not blank the
    /// member's display name as a side effect.
    struct ProfileUpdate: Encodable {
        var displayName: String? = nil
        var username: String? = nil
        var bio: String? = nil
        var inboxPolicy: String? = nil
        var isDiscoverable: Bool? = nil
        var hideMessagePreviews: Bool? = nil
        var notifyAnnouncements: Bool? = nil
        var notifyDm: Bool? = nil
        var notifyFriendRequests: Bool? = nil
        var notifyChannelPosts: Bool? = nil
        var timezone: String? = nil
    }

    func updateProfile(_ update: ProfileUpdate) async throws {
        do {
            let _: AuthUser = try await api.put("/api/auth/profile", body: update)
            await reloadUser()
        } catch APIError.decodingError {
            // The route may answer with an envelope or 204; the write landed.
            await reloadUser()
        } catch let APIError.httpError(_, message) {
            throw AuthError.message(message ?? "Couldn't save those changes.")
        }
    }

    func updateProfile(displayName: String) async throws {
        try await updateProfile(ProfileUpdate(displayName: displayName))
    }

    /// §4.4's inbox policy. Flipping to `friends_only` blocks NEW conversations
    /// only — existing threads are grandfathered, and the settings copy says so.
    func updateProfile(inboxPolicy: String) async throws {
        try await updateProfile(ProfileUpdate(inboxPolicy: inboxPolicy))
    }

    /// §4.3.5's preview flag. The caller ALSO mirrors it into the App Group; the
    /// column alone is inert, because the notification extension cannot read
    /// Postgres and the server has ciphertext with nothing to redact.
    func updateProfile(hideMessagePreviews: Bool) async throws {
        try await updateProfile(ProfileUpdate(hideMessagePreviews: hideMessagePreviews))
    }

    func uploadAvatar(_ imageData: Data, fileName: String = "avatar.jpg", mimeType: String = "image/jpeg") async throws {
        let _: EmptyResponse = try await api.upload("/api/auth/avatar", fileData: imageData, fileName: fileName, mimeType: mimeType)
        await reloadUser()
    }

    struct ChangePasswordBody: Encodable {
        /// Absent for a SIWA-only member adding a password for the first time.
        let currentPassword: String?
        let newPassword: String
    }

    func changePassword(current: String?, new: String) async throws {
        try await api.postVoid("/api/auth/change-password",
                               body: ChangePasswordBody(currentPassword: current, newPassword: new))
    }

    func resendVerification() async throws {
        try await api.postVoid("/api/auth/resend-verification")
    }

    // MARK: - Password reset

    struct ForgotBody: Encodable { let email: String }
    struct ResetBody: Encodable { let token: String; let newPassword: String }

    /// Always succeeds from the caller's point of view for a nonexistent
    /// address — the server does not confirm whether an address is registered,
    /// and neither does the UI.
    func forgotPassword(email: String) async throws {
        do {
            try await api.postVoid("/api/auth/forgot-password", body: ForgotBody(email: email))
        } catch let APIError.httpError(code, message) where code != 429 {
            throw AuthError.message(message ?? "Couldn't send that reset link.")
        }
    }

    func resetPassword(token: String, newPassword: String) async throws {
        do {
            try await api.postVoid("/api/auth/reset-password", body: ResetBody(token: token, newPassword: newPassword))
        } catch let APIError.httpError(_, message) {
            throw AuthError.message(message ?? "That reset link didn't work.")
        }
    }

    // MARK: - Account lifecycle

    /// Guideline 5.1.1(v). The server revokes the Apple grant, scrambles the
    /// identifying columns, tombstones the row and drops every token and device
    /// registration (PLAN.md §2.1). There is no undo.
    func deleteAccount() async throws {
        do {
            try await api.delete("/api/auth/account")
        } catch let APIError.httpError(_, message) {
            throw AuthError.message(message ?? "We couldn't delete the account.")
        }
        OnboardingService.shared.forgetLocalState(for: user?.id)
        signOut()
    }

    func signOut() {
        // Best-effort APNs unregister FIRST — it captures the current bearer
        // synchronously before we clear the token below (the async DELETE would
        // otherwise run after sign-out and 401).
        PushCoordinator.shared.unregister()

        // Server-side logout, same trick: capture the bearer NOW. Anything that
        // reads `api.accessToken` inside the Task reads it after the clear below
        // and sends an unauthenticated request.
        if let bearer = api.accessToken {
            let url = URL(string: api.baseURL + "/api/auth/logout")!
            Task.detached {
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue(FWBConfig.appId, forHTTPHeaderField: "X-App-Id")
                req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
                req.timeoutInterval = 15
                _ = try? await URLSession.shared.data(for: req)
            }
        }

        api.accessToken = nil
        api.refreshToken = nil
        user = nil
        OnboardingService.shared.reset()
    }
}
