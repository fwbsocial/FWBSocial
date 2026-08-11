import Foundation

// MARK: - Onboarding endpoints (EULA acceptance + age attestation)
//
// ⚠️ CONTRACT STATUS — read before changing anything here.
//
// PLAN.md §2.1 specifies the `fwb_user_agreements` table and §6.1 requires
// acceptance to be recorded at signup; commissioner decision Q16 requires the
// Declared Age Range attestation to be reported. fwb-server has the
// `UserAgreement` model but, as of this build, mounts **no route** for either —
// `routes.swift` goes straight from `/api/auth/account` to `/api/push`.
//
// So these two paths are the client's proposal, named to match the server's
// existing `/api/auth/...` convention and its snake_case wire style:
//
//   POST /api/auth/agreements       { doc, version }                    -> 2xx
//   GET  /api/auth/agreements       { items: [{ doc, version, ... }] }
//   POST /api/auth/age-attestation  { threshold, meets_threshold, ... }  -> 2xx
//
// Every call degrades gracefully: a 404/405 is reported as
// `.routeNotDeployed` rather than thrown, so a member is never blocked at the
// door by a route that has not shipped yet. `OnboardingService` keeps the
// acceptance locally and replays it on a later launch. When the server side
// lands, the only thing that may need changing is the three path strings and
// the two request shapes below.

/// Which of the three hosted documents an acceptance row refers to. Mirrors
/// fwb-server's `AgreementDoc`.
enum AgreementDoc: String, Codable, Sendable, CaseIterable {
    case eula
    case privacy
    case guidelines
}

/// The outcome of a call that the server may not implement yet.
enum OnboardingSyncResult: Sendable, Equatable {
    case recorded
    case routeNotDeployed
}

nonisolated struct AgreementRecord: Decodable, Sendable {
    let doc: String
    let version: String
    let acceptedAt: Date?
}

nonisolated struct AgreementListResponse: Decodable, Sendable {
    let items: [AgreementRecord]
}

extension APIClient {

    private struct AcceptAgreementBody: Encodable {
        let doc: String
        let version: String
    }

    /// Report a Declared Age Range result.
    ///
    /// Deliberately carries the *band*, never a birthdate — that is the entire
    /// point of the API (PLAN.md §6.3). `lowerBound`/`upperBound` are whatever
    /// Apple returned for the 18 gate (either may be nil: an open-ended band is
    /// normal), and `declaration` records how the range was established
    /// (`self_declared`, `guardian_declared`, `confirmed`, …) so a later audit
    /// can tell a self-declaration from a verified one.
    private struct AgeAttestationBody: Encodable {
        let threshold: Int
        let meetsThreshold: Bool
        let lowerBound: Int?
        let upperBound: Int?
        let declaration: String?
        let source: String
    }

    /// Record acceptance of one hosted document.
    @discardableResult
    func acceptAgreement(doc: AgreementDoc, version: String) async throws -> OnboardingSyncResult {
        do {
            try await postVoid("/api/auth/agreements",
                               body: AcceptAgreementBody(doc: doc.rawValue, version: version))
            return .recorded
        } catch let APIError.httpError(code, _) where code == 404 || code == 405 {
            return .routeNotDeployed
        }
    }

    /// What the server already has on file for this member. Returns `nil` when
    /// the route isn't deployed, which is distinct from "accepted nothing".
    func fetchAgreements() async throws -> [AgreementRecord]? {
        do {
            let response: AgreementListResponse = try await get("/api/auth/agreements")
            return response.items
        } catch let APIError.httpError(code, _) where code == 404 || code == 405 {
            return nil
        } catch APIError.decodingError {
            return nil
        }
    }

    /// Report the age-range declaration.
    @discardableResult
    func reportAgeAttestation(
        threshold: Int,
        meetsThreshold: Bool,
        lowerBound: Int?,
        upperBound: Int?,
        declaration: String?,
        source: String = "declared_age_range"
    ) async throws -> OnboardingSyncResult {
        do {
            try await postVoid(
                "/api/auth/age-attestation",
                body: AgeAttestationBody(
                    threshold: threshold,
                    meetsThreshold: meetsThreshold,
                    lowerBound: lowerBound,
                    upperBound: upperBound,
                    declaration: declaration,
                    source: source))
            return .recorded
        } catch let APIError.httpError(code, _) where code == 404 || code == 405 {
            return .routeNotDeployed
        }
    }
}
