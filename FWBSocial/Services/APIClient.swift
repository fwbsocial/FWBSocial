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

    var baseURL: String { FWBConfig.baseURL }
    private let appId = FWBConfig.appId

    private let accessTokenKey  = "fwb.accessToken"
    private let refreshTokenKey = "fwb.refreshToken"

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

            if http.statusCode == 401 || http.statusCode == 403 {
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

    /// Try to surface a server-provided error `reason`/`error` message.
    private static func serverMessage(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (obj["reason"] as? String) ?? (obj["error"] as? String) ?? (obj["message"] as? String)
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
            if http.statusCode == 401 || http.statusCode == 403 {
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
