import Foundation

// MARK: - Shared JSON coders (ported from Flux's FluxJSON)
//
// Wire format is snake_case with ISO8601 timestamps WITHOUT fractional seconds.
// Use these statics EVERYWHERE so encode/decode strategy can't drift. Response
// models use camelCase properties + `.convertFromSnakeCase` (NO CodingKeys unless
// a key can't round-trip). Timestamp fields are modeled as `String?` where they
// mirror a web wire type; parse on demand via `FWBDate`.

enum FWBJSON {
    /// Decoder for all API responses: snake_case → camelCase, ISO8601 dates.
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Encoder for all API request bodies: camelCase → snake_case, ISO8601 dates.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

// MARK: - ISO8601 parsing helper

enum FWBDate {
    /// ISO8601 WITHOUT fractional seconds (matches the backend encoder).
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Tolerant variant that also accepts fractional seconds, just in case.
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Parse a wire timestamp string into a `Date`, or `nil`.
    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return iso.date(from: string) ?? isoFractional.date(from: string)
    }
}

// MARK: - Pagination

/// Standard paged envelope: `{ items: [...], metadata: { page, per, total } }`.
nonisolated struct PagedResponse<T: Decodable & Sendable>: Decodable, Sendable {
    let items: [T]
    let metadata: PageMetadata?
}

nonisolated struct PageMetadata: Decodable, Sendable {
    let page: Int
    let per: Int
    let total: Int
}

// MARK: - Trivial response shapes

/// `{ available: Bool }` (slug/username availability, etc.).
nonisolated struct AvailabilityResponse: Decodable, Sendable { let available: Bool }

/// `{ count: Int }`.
nonisolated struct CountResponse: Decodable, Sendable { let count: Int }

/// An empty body for endpoints whose response we ignore.
nonisolated struct EmptyResponse: Decodable, Sendable {
    init() {}
    init(from decoder: Decoder) throws {}
}
