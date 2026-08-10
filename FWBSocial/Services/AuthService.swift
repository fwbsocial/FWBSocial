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
// Ported from Flux's `AuthService` (PLAN.md §5.2 / §3). Stripped: two-factor
// auth (dropped for v1 across the fleet's fork of this controller — device
// approval is FWB's second factor, PLAN.md §3) and event-password plumbing
// (Flux-specific). Added: `authorizationCode` on the Sign in with Apple call —
// required for `POST https://appleid.apple.com/auth/revoke` at account
// deletion (PLAN.md §3.1); the server exchanges it for a refresh token at
// sign-in time since the code is single-use.

@Observable
@MainActor
final class AuthService {

    static let shared = AuthService()

    /// The signed-in user, or `nil` when signed out.
    private(set) var user: AuthUser?

    /// True once the initial session-restore attempt has completed.
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
        } catch {
            logger.debug("Session restore failed: \(error.localizedDescription)")
            // Leave tokens in place; a transient failure shouldn't force sign-out.
        }
    }

    // MARK: - Login / register

    struct LoginBody: Encodable { let email: String; let password: String }
    struct RegisterBody: Encodable { let displayName: String; let email: String; let password: String }
    struct AppleSignInBody: Encodable { let identityToken: String; let authorizationCode: String; let displayName: String? }

    func login(email: String, password: String) async throws {
        let body = LoginBody(email: email, password: password)
        do {
            let resp: AuthTokenResponse = try await api.request(
                "POST", "/api/auth/login",
                body: try FWBJSON.encoder.encode(body),
                retryOnUnauth: false)
            try applyTokens(resp)
        } catch let APIError.httpError(code, message) {
            if code == 401 { throw AuthError.invalidCredentials }
            throw AuthError.message(message ?? "Sign in failed.")
        } catch APIError.unauthorized {
            throw AuthError.invalidCredentials
        }
    }

    func register(displayName: String, email: String, password: String) async throws {
        let body = RegisterBody(displayName: displayName, email: email, password: password)
        let resp: AuthTokenResponse = try await api.request(
            "POST", "/api/auth/register",
            body: try FWBJSON.encoder.encode(body),
            retryOnUnauth: false)
        try applyTokens(resp)
    }

    /// Sign in with Apple. `authorizationCode` (from `ASAuthorizationAppleIDCredential`)
    /// is REQUIRED, not optional — the server exchanges it once, at sign-in time,
    /// for the refresh token account deletion needs to revoke the Apple grant
    /// (PLAN.md §3.1). The code is single-use and short-lived; losing it here
    /// means every SIWA account becomes unrevocable at the first deletion.
    func appleSignIn(identityToken: String, authorizationCode: String, displayName: String? = nil) async throws {
        let body = AppleSignInBody(identityToken: identityToken, authorizationCode: authorizationCode, displayName: displayName)
        let resp: AuthTokenResponse = try await api.request(
            "POST", "/api/auth/apple",
            body: try FWBJSON.encoder.encode(body),
            retryOnUnauth: false)
        try applyTokens(resp)
    }

    private func applyTokens(_ resp: AuthTokenResponse) throws {
        guard let access = resp.resolvedAccessToken else {
            throw AuthError.message("The server didn't return a session token.")
        }
        api.accessToken = access
        if let refresh = resp.refreshToken { api.refreshToken = refresh }
        if let u = resp.user {
            user = u
            // Now signed in — flush any cached APNs token to the backend.
            PushCoordinator.shared.syncRegistration()
        } else {
            Task {
                self.user = try? await self.fetchMe()
                if self.user != nil { PushCoordinator.shared.syncRegistration() }
            }
        }
    }

    // MARK: - Refresh

    /// The single in-flight refresh, shared by all concurrent callers.
    ///
    /// When multiple views mount at once, their first fetches can 401
    /// simultaneously and each ask for a refresh. Without coalescing, N
    /// concurrent refreshes each read the SAME single-use refresh token from the
    /// Keychain and POST `/api/auth/refresh` — the server rotates the token on the
    /// first POST, so every later POST double-spends an already-consumed token
    /// and fails. Storing the Task here makes it single-flight: the first caller
    /// creates the Task, all others await the same one.
    private var refreshTask: Task<Bool, Never>?

    /// Refresh the access token. Returns `true` on success. Called by `APIClient`
    /// on a 401/403. Single-flight: concurrent callers share one in-flight refresh.
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

    /// The actual refresh POST. Only ever runs one-at-a-time via `refresh()`.
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
            return false
        }
    }

    // MARK: - Me

    func fetchMe() async throws -> AuthUser {
        // `/me` may return the user directly or wrapped in `{ user: ... }`.
        struct Wrapped: Decodable { let user: AuthUser }
        let data: Data = try await rawGet("/api/auth/me")
        if let u = try? FWBJSON.decoder.decode(AuthUser.self, from: data) { return u }
        return try FWBJSON.decoder.decode(Wrapped.self, from: data).user
    }

    /// Refresh the cached user from `/me`.
    func reloadUser() async {
        user = try? await fetchMe()
    }

    private func rawGet(_ path: String) async throws -> Data {
        // Fetch raw bytes directly so we can try both `/me` response shapes.
        var req = URLRequest(url: URL(string: api.baseURL + path)!)
        req.setValue(FWBConfig.appId, forHTTPHeaderField: "X-App-Id")
        if let token = api.accessToken { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 30
        let (bytes, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            if await refresh() { return try await rawGet(path) }
            throw APIError.unauthorized
        }
        return bytes
    }

    // MARK: - Profile

    struct ProfileUpdate: Encodable { var displayName: String? }

    func updateProfile(displayName: String) async throws {
        let _: EmptyResponse = try await api.put("/api/auth/profile", body: ProfileUpdate(displayName: displayName))
        await reloadUser()
    }

    func uploadAvatar(_ imageData: Data, fileName: String = "avatar.jpg", mimeType: String = "image/jpeg") async throws {
        let _: EmptyResponse = try await api.upload("/api/auth/avatar", fileData: imageData, fileName: fileName, mimeType: mimeType)
        await reloadUser()
    }

    struct ChangePasswordBody: Encodable { let currentPassword: String; let newPassword: String }

    func changePassword(current: String, new: String) async throws {
        try await api.postVoid("/api/auth/change-password",
                               body: ChangePasswordBody(currentPassword: current, newPassword: new))
    }

    func resendVerification() async throws {
        try await api.postVoid("/api/auth/resend-verification")
    }

    // MARK: - Password reset

    struct ForgotBody: Encodable { let email: String }
    struct ResetBody: Encodable { let token: String; let newPassword: String }

    func forgotPassword(email: String) async throws {
        try await api.postVoid("/api/auth/forgot-password", body: ForgotBody(email: email))
    }

    func resetPassword(token: String, newPassword: String) async throws {
        try await api.postVoid("/api/auth/reset-password", body: ResetBody(token: token, newPassword: newPassword))
    }

    // MARK: - Account lifecycle

    func deleteAccount() async throws {
        try await api.delete("/api/auth/account")
        signOut()
    }

    func signOut() {
        // Best-effort APNs unregister FIRST — it captures the current bearer
        // synchronously before we clear the token below (the async DELETE would
        // otherwise run after sign-out and 401).
        PushCoordinator.shared.unregister()
        api.accessToken = nil
        api.refreshToken = nil
        user = nil
    }
}
