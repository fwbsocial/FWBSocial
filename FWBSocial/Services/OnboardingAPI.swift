import Foundation

// MARK: - Onboarding endpoints (EULA acceptance + age gate)
//
// Verified against the deployed fwb-server
// (Sources/App/Auth/AgeAndAgreements.swift):
//
//   GET  /api/onboarding/status      -> OnboardingStatus
//   POST /api/onboarding/agreements  { docs?, version? }  -> OnboardingStatus
//   POST /api/onboarding/age         { age_range }        -> OnboardingStatus, or 403
//
// All three are authenticated but deliberately NOT vetting-gated: onboarding is
// how a member becomes vetted, so gating it behind vetting would deadlock.
//
// Two server behaviours the client has to respect rather than work around:
//
//  * **Version conflict is a 409.** The server checks the version the client
//    displayed against its own current version, so a stale build cannot record
//    acceptance of text the member never saw. The right response is "update the
//    app", not a retry.
//
//  * **A declared minor is a 403.** `POST /onboarding/age` records the band
//    first and *then* refuses, so re-running the flow doesn't hand a minor
//    another go at the dialog. The client must read that 403 as a hard stop.

/// Which of the three hosted documents an acceptance row refers to. Mirrors
/// fwb-server's `AgreementDoc`.
enum AgreementDoc: String, Codable, Sendable, CaseIterable {
    case eula
    case privacy
    case guidelines
}

/// fwb-server's `OnboardingStatusResponse` — the authority on what a member
/// still owes.
nonisolated struct OnboardingStatus: Decodable, Sendable {
    let vettingState: String?
    let acceptedAll: Bool
    let missingDocs: [String]
    /// doc → version currently in force. The client echoes the EULA's version
    /// back on acceptance so a stale build is rejected rather than silently
    /// recording the wrong text.
    let currentVersions: [String: String]?
    /// `unknown` | `under_13` | `13_to_15` | `16_to_17` | `18_or_over`, or nil
    /// if never asked. `unknown` is NOT the same as never having asked, and not
    /// the same as a minor.
    let declaredAgeRange: String?
    let ageDeclared: Bool
    let isDeclaredAdult: Bool
    /// True when the client should run the Declared Age Range flow — either it
    /// has never been asked, or the last answer was `unknown`.
    let ageDeclarationRequired: Bool
}

/// A `POST /onboarding/age` that came back 403: the member declared a band
/// below 18 and the server has already recorded it.
struct DeclaredMinorError: LocalizedError {
    var errorDescription: String? { "You must be 18 or over to use fwb social." }
}

/// The hosted text has moved on and this build is showing the old version.
struct AgreementVersionConflictError: LocalizedError {
    let reason: String?
    var errorDescription: String? {
        reason ?? "The terms have been updated — please update the app and review them again."
    }
}

extension APIClient {

    private struct AcceptAgreementsBody: Encodable {
        /// Omitted means "all required docs", which is exactly what the
        /// onboarding screen presents in one step.
        let docs: [String]?
        let version: String?
    }

    private struct DeclareAgeBody: Encodable {
        let ageRange: String
    }

    /// What the member still owes. `nil` when the route isn't reachable, which
    /// is deliberately distinct from "owes nothing".
    func onboardingStatus() async throws -> OnboardingStatus? {
        do {
            return try await get("/api/onboarding/status")
        } catch let APIError.httpError(code, _) where code == 404 || code == 405 {
            return nil
        }
    }

    /// Accept every required document at the version this build displayed.
    @discardableResult
    func acceptAgreements(version: String) async throws -> OnboardingStatus? {
        do {
            return try await post(
                "/api/onboarding/agreements",
                body: AcceptAgreementsBody(docs: nil, version: version))
        } catch let APIError.httpError(code, message) where code == 409 {
            throw AgreementVersionConflictError(reason: message)
        } catch let APIError.httpError(code, _) where code == 404 || code == 405 {
            return nil
        }
    }

    /// Report the Declared Age Range band. Throws `DeclaredMinorError` on the
    /// server's 403 — the band is recorded either way.
    @discardableResult
    func declareAgeRange(_ band: DeclaredAgeBand) async throws -> OnboardingStatus? {
        do {
            return try await post("/api/onboarding/age", body: DeclareAgeBody(ageRange: band.rawValue))
        } catch let APIError.httpError(code, _) where code == 403 {
            throw DeclaredMinorError()
        } catch APIError.unauthorized {
            // `APIClient` maps 403 to `.unauthorized` after a failed refresh, so
            // the minor refusal can surface through this path too. A 403 on this
            // specific route always means the age refusal — the caller is
            // authenticated by definition, having just been issued a token.
            throw DeclaredMinorError()
        } catch let APIError.httpError(code, _) where code == 404 || code == 405 {
            return nil
        }
    }
}
