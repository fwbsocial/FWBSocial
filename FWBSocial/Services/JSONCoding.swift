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

/// Standard paged envelope: `{ items: [...], metadata: { page, per, total } }` —
/// Vapor's `Fluent.Page` shape, which is what `.paginate()` emits.
///
/// **Decodes tolerantly on purpose.** A cacheable, unauthenticated collection
/// route is often written to return a bare JSON array (it ETags better and the
/// envelope buys nothing when there's no cursor), and `/api/public/announcements`
/// is exactly that kind of route — PLAN.md §4.1 specifies the caching, not the
/// envelope. Accepting `{items:…}`, `{data:…}` and `[…]` means a reasonable
/// server-side choice can't turn into a client outage. A bare array is treated
/// as a complete, unpaginated page.
nonisolated struct PagedResponse<T: Decodable & Sendable>: Decodable, Sendable {
    let items: [T]
    let metadata: PageMetadata?

    init(items: [T], metadata: PageMetadata? = nil) {
        self.items = items
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case items, metadata, data, results, meta, pagination
    }

    init(from decoder: Decoder) throws {
        // Bare array first — it has no keys to inspect.
        if let single = try? decoder.singleValueContainer(),
           let array = try? single.decode([T].self) {
            self.items = array
            self.metadata = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let array = try container.decodeIfPresent([T].self, forKey: .items) {
            self.items = array
        } else if let array = try container.decodeIfPresent([T].self, forKey: .data) {
            self.items = array
        } else if let array = try container.decodeIfPresent([T].self, forKey: .results) {
            self.items = array
        } else {
            self.items = []
        }

        self.metadata = (try? container.decodeIfPresent(PageMetadata.self, forKey: .metadata))
            ?? (try? container.decodeIfPresent(PageMetadata.self, forKey: .meta))
            ?? (try? container.decodeIfPresent(PageMetadata.self, forKey: .pagination))
            ?? nil
    }
}

nonisolated struct PageMetadata: Decodable, Sendable {
    let page: Int?
    let per: Int?
    let total: Int?
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
