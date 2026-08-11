import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: "events.fwb.social", category: "APIClient")

// MARK: - Errors

enum APIError: LocalizedError {
    case invalidURL
    case unauthorized
    case httpError(Int, message: String?)
    case rateLimited(retryAfter: Int?)
    case decodingError(Error)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:               return "Invalid URL."
        case .unauthorized:             return "Please sign in again."
        case .rateLimited:              return "You're doing that too fast — please wait a moment."
        case .httpError(let code, let m): return m ?? "Server returned HTTP \(code)."
        case .decodingError(let e):     return "Couldn't read the server's response. \(e.localizedDescription)"
        case .networkError(let e):      return e.localizedDescription
        }
    }

    var statusCode: Int? {
        if case .httpError(let code, _) = self { return code }
        if case .unauthorized = self { return 401 }
        return nil
    }
}

// MARK: - API Client
//
// Ported near-verbatim from Flux's `APIClient` (PLAN.md §5.2) — generic REST
// verbs + multipart, auto JWT refresh on 401. The one substantive change is the
// base URL: it reads `FWBConfig.baseURL` (a dev/prod indirection) instead of a
// hardcoded production host.

@Observable
@MainActor
final class APIClient {

    static let shared = APIClient()

    /// DEBUG-only: seed the session from the launch environment.
    ///
    /// UI smokes were spending most of their runtime driving a sign-in form, and
    /// losing runs to it — iOS's strong-password sheet steals focus from a
    /// `SecureField` the moment it takes focus, and the failure surfaces much later
    /// as "that email or password didn't match", which points at seeding rather
    /// than at stolen keystrokes.
    ///
    /// Authentication itself is covered by `SmokeTests`, which drives the real form
    /// deliberately. Every OTHER smoke wants a session, not a sign-in, and this is
    /// the same DEBUG-only seam `FWB_API_BASE` already established.
    ///
    /// Compiled out of Release, so a shipped build cannot have a session handed to
    /// it by an environment variable.
    private func seedSessionFromEnvironmentIfNeeded() {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard let token = environment["FWB_SESSION_TOKEN"], !token.isEmpty else { return }
        KeychainHelper.save(key: accessTokenKey, value: token, service: KeychainHelper.authService)
        if let refresh = environment["FWB_REFRESH_TOKEN"], !refresh.isEmpty {
            KeychainHelper.save(key: refreshTokenKey, value: refresh, service: KeychainHelper.authService)
        }
        #endif
    }

    var baseURL: String { FWBConfig.baseURL }
    private let appId = FWBConfig.appId

    private let accessTokenKey  = "fwb.accessToken"
    private let refreshTokenKey = "fwb.refreshToken"

    private init() {
        seedSessionFromEnvironmentIfNeeded()
    }

    // MARK: - Token storage (Keychain-backed)

    var accessToken: String? {
        get { KeychainHelper.load(key: accessTokenKey, service: KeychainHelper.authService) }
        set {
            if let newValue { KeychainHelper.save(key: accessTokenKey, value: newValue, service: KeychainHelper.authService) }
            else { KeychainHelper.delete(key: accessTokenKey, service: KeychainHelper.authService) }
        }
    }

    var refreshToken: String? {
        get { KeychainHelper.load(key: refreshTokenKey, service: KeychainHelper.authService) }
        set {
            if let newValue { KeychainHelper.save(key: refreshTokenKey, value: newValue, service: KeychainHelper.authService) }
            else { KeychainHelper.delete(key: refreshTokenKey, service: KeychainHelper.authService) }
        }
    }

    var isAuthenticated: Bool { accessToken != nil }

    // MARK: - Request building

    private func buildRequest(
        method: String,
        path: String,
        body: Data? = nil,
        contentType: String? = "application/json"
    ) throws -> URLRequest {
        // `path` may be a full path ("/api/...") or already-absolute URL.
        let urlString = path.hasPrefix("http") ? path : baseURL + path
        guard let url = URL(string: urlString) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(appId, forHTTPHeaderField: "X-App-Id")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        }
        request.timeoutInterval = 30
        return request
    }

    // MARK: - Core request

    /// Perform a request and decode `T`. Auto-refreshes the token once on 401/403.
    func request<T: Decodable>(
        _ method: String,
        _ path: String,
        body: Data? = nil,
        retryOnUnauth: Bool = true
    ) async throws -> T {
        let req = try buildRequest(method: method, path: path, body: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw APIError.httpError(0, message: nil) }

            // **401 only.** The ported source refreshed on 403 too, which is
            // wrong here and actively harmful: fwb-server uses 403 for real
            // authorization decisions — `RequireVettedMember`, `RequireAdmin`,
            // and the age gate's declared-minor refusal. Refreshing can never
            // fix any of those, and reporting them as `.unauthorized` makes
            // `AuthService` sign the member out for the crime of tapping an
            // admin route. A 403 is an answer; it is passed through with its
            // reason intact.
            if http.statusCode == 401 {
                if retryOnUnauth, await AuthService.shared.refresh() {
                    return try await request(method, path, body: body, retryOnUnauth: false)
                }
                throw APIError.unauthorized
            }

            if http.statusCode == 429 {
                let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap { Int($0) }
                throw APIError.rateLimited(retryAfter: retryAfter)
            }

            guard (200...299).contains(http.statusCode) else {
                throw APIError.httpError(http.statusCode, message: Self.serverMessage(from: data))
            }

            if T.self == EmptyResponse.self { return EmptyResponse() as! T }

            do {
                return try FWBJSON.decoder.decode(T.self, from: data)
            } catch {
                logger.error("Decode error for \(path): \(String(describing: error))")
                throw APIError.decodingError(error)
            }
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.networkError(error)
        }
    }

    /// Try to surface a server-provided error message.
    ///
    /// fwb-server emits **two** error shapes and this has to read both:
    ///
    ///   Vapor's default   `{ "reason": "..." }`
    ///   Structured        `{ "error": { "code": "account.pending_vetting",
    ///                                   "message": "You'll get access once …" } }`
    ///
    /// The nested one comes from `RequireVettedMember` and carries the account
    /// state (`pending_vetting`, `banned`, `vetting_revoked`, `rejected`). Reading
    /// only the flat shape — as this did — meant `obj["error"]` was a dictionary,
    /// the `as? String` cast failed, and every vetting and ban response degraded
    /// to "Server returned HTTP 403" while the server was in fact explaining
    /// itself perfectly well.
    ///
    /// Surfacing `error.message` is also what lets a 403 screen distinguish
    /// pending from banned from revoked **without** matching on codes: the server
    /// already wrote the right sentence for each.
    private static func serverMessage(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        if let nested = obj["error"] as? [String: Any] {
            if let message = nested["message"] as? String { return message }
            if let code = nested["code"] as? String { return code }
        }
        return (obj["reason"] as? String)
            ?? (obj["error"] as? String)
            ?? (obj["message"] as? String)
    }

    /// The structured error code, when the server sent one
    /// (`account.pending_vetting`, `account.banned`, …). Nil for Vapor's flat
    /// `reason` shape.
    nonisolated static func serverErrorCode(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nested = obj["error"] as? [String: Any] else { return nil }
        return nested["code"] as? String
    }

    // MARK: - Convenience verbs

    func get<T: Decodable>(_ path: String) async throws -> T {
        try await request("GET", path)
    }

    @discardableResult
    func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        try await request("POST", path, body: try FWBJSON.encoder.encode(body))
    }

    @discardableResult
    func post<T: Decodable>(_ path: String) async throws -> T {
        try await request("POST", path)
    }

    @discardableResult
    func put<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        try await request("PUT", path, body: try FWBJSON.encoder.encode(body))
    }

    @discardableResult
    func patch<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        try await request("PATCH", path, body: try FWBJSON.encoder.encode(body))
    }

    @discardableResult
    func patch<T: Decodable>(_ path: String) async throws -> T {
        try await request("PATCH", path)
    }

    /// DELETE with a decoded response body.
    @discardableResult
    func delete<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        try await request("DELETE", path)
    }

    /// DELETE with no meaningful response body.
    func delete(_ path: String) async throws {
        let _: EmptyResponse = try await request("DELETE", path)
    }

    /// POST with a body but no response body needed.
    func postVoid<B: Encodable>(_ path: String, body: B) async throws {
        let _: EmptyResponse = try await request("POST", path, body: try FWBJSON.encoder.encode(body))
    }

    /// POST with neither a request body nor a response body.
    func postVoid(_ path: String) async throws {
        let _: EmptyResponse = try await request("POST", path)
    }

    // MARK: - Multipart upload

    /// Upload a single file via multipart/form-data and decode `T`.
    /// `fields` are additional text form fields.
    @discardableResult
    func upload<T: Decodable>(
        _ path: String,
        fileData: Data,
        fileName: String,
        mimeType: String,
        fieldName: String = "file",
        fields: [String: String] = [:],
        retryOnUnauth: Bool = true
    ) async throws -> T {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }

        for (k, v) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(k)\"\r\n\r\n")
            append("\(v)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")

        let req = try buildRequest(
            method: "POST",
            path: path,
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw APIError.httpError(0, message: nil) }
            if http.statusCode == 401 {
                if retryOnUnauth, await AuthService.shared.refresh() {
                    return try await upload(path, fileData: fileData, fileName: fileName, mimeType: mimeType,
                                            fieldName: fieldName, fields: fields, retryOnUnauth: false)
                }
                throw APIError.unauthorized
            }
            guard (200...299).contains(http.statusCode) else {
                throw APIError.httpError(http.statusCode, message: Self.serverMessage(from: data))
            }
            if T.self == EmptyResponse.self { return EmptyResponse() as! T }
            return try FWBJSON.decoder.decode(T.self, from: data)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.networkError(error)
        }
    }
}

/// Placeholder for "no body" default arguments.
struct EmptyBody: Encodable {}

/// True when `error` represents task/URL cancellation rather than a genuine
/// failure. A cancelled `URLSession` request surfaces as `URLError.cancelled`
/// (wrapped by `APIClient` as `.networkError`), while a cancelled Swift `Task`
/// can surface as `CancellationError` — callers should treat neither as a load
/// failure.
nonisolated func isCancellationError(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    if case APIError.networkError(let underlying) = error {
        if underlying is CancellationError { return true }
        if let urlError = underlying as? URLError, urlError.code == .cancelled { return true }
    }
    return false
}

// MARK: - Query helpers

extension APIClient {
    /// Build a path with URL-encoded query items, dropping nil values.
    nonisolated static func path(_ base: String, query: [String: String?]) -> String {
        var comps = URLComponents()
        comps.queryItems = query.compactMap { key, value in
            value.map { URLQueryItem(name: key, value: $0) }
        }.sorted { $0.name < $1.name }
        let q = comps.percentEncodedQuery
        return (q?.isEmpty == false) ? "\(base)?\(q!)" : base
    }
}
