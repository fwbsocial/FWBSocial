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

/// A page of results, decoded from whichever envelope the route actually uses.
///
/// **fwb-server's announcements feed is FLAT**: `{ items, total, page, per,
/// has_more }`, and `AnnouncementDTOs.swift` says why — it is deliberately not
/// Fluent's `Page`, because that route is the one surface App Review sees signed
/// out and a hand-rolled shape can't shift underneath it. Fluent's nested
/// `{ items, metadata: { page, per, total } }` is still accepted, as is a bare
/// array, so a route that picks a different shape can't become a client outage.
///
/// `hasMore` is authoritative when present: it's the server saying so, which
/// beats inferring the end of the feed from a short page.
nonisolated struct PagedResponse<T: Decodable & Sendable>: Decodable, Sendable {
    let items: [T]
    let metadata: PageMetadata?
    let hasMore: Bool?

    init(items: [T], metadata: PageMetadata? = nil, hasMore: Bool? = nil) {
        self.items = items
        self.metadata = metadata
        self.hasMore = hasMore
    }

    private enum CodingKeys: String, CodingKey {
        case items, metadata, data, results, meta, pagination
        case page, per, total, hasMore
    }

    init(from decoder: Decoder) throws {
        // Bare array first — it has no keys to inspect.
        if let single = try? decoder.singleValueContainer(),
           let array = try? single.decode([T].self) {
            self.items = array
            self.metadata = nil
            self.hasMore = nil
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

        self.hasMore = try? container.decodeIfPresent(Bool.self, forKey: .hasMore)

        if let nested = (try? container.decodeIfPresent(PageMetadata.self, forKey: .metadata))
            ?? (try? container.decodeIfPresent(PageMetadata.self, forKey: .meta))
            ?? (try? container.decodeIfPresent(PageMetadata.self, forKey: .pagination)) {
            self.metadata = nested
        } else {
            // Flat form — the shape fwb-server actually emits.
            let page = try? container.decodeIfPresent(Int.self, forKey: .page)
            let per = try? container.decodeIfPresent(Int.self, forKey: .per)
            let total = try? container.decodeIfPresent(Int.self, forKey: .total)
            self.metadata = (page ?? per ?? total) == nil
                ? nil
                : PageMetadata(page: page ?? nil, per: per ?? nil, total: total ?? nil)
        }
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
