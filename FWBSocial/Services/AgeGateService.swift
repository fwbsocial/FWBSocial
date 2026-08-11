import DeclaredAgeRange
import Foundation
import OSLog

private let ageLog = Logger(subsystem: "events.fwb.social", category: "AgeGate")

// MARK: - Age gate
//
// Commissioner decision Q16: the 18+ gate is Apple's **Declared Age Range API**,
// not a self-declared birthdate. PLAN.md §6.3 spells out why — if the rating
// lands 17+/18+, adopting the API up front is cheap and retrofitting means
// re-vetting the entire existing membership.
//
// What the API actually gives us is a *band*, never a birthdate: we ask "is this
// person above 18?" and get back either a refusal to answer or a range whose
// bounds straddle that threshold. Nothing else about the person's age is
// disclosed to the app, and there is nothing else to store.
//
// Requires the `com.apple.developer.declared-age-range` entitlement
// (`FWBSocial.entitlements`) and the matching portal capability on App ID
// `events.fwb.social`. Without it, `AgeRangeService` throws `.notAvailable`.

/// How the member's age band was established, flattened to a wire string. The
/// distinction matters for an audit: a self-declaration is a weaker claim than a
/// guardian declaration or a verified one, and the server should be able to tell
/// them apart later without re-asking.
enum AgeDeclarationKind: String, Sendable {
    case selfDeclared = "self_declared"
    case guardianDeclared = "guardian_declared"
    case confirmed = "confirmed"
    case unspecified = "unspecified"
}

/// The gate's verdict.
enum AgeGateOutcome: Sendable, Equatable {
    /// The declared band sits at or above the threshold. Proceed.
    case passed(AgeGateAttestation)
    /// Declared under the threshold, or the member declined to share. Hard stop.
    case blocked(reason: BlockReason)
    /// The API could not run at all — no entitlement, unsupported platform or
    /// region, or a system error. See `AgeGatePolicy.allowWhenUnavailable`.
    case unavailable(message: String)

    enum BlockReason: String, Sendable {
        case underAge = "under_age"
        case declined = "declined"
    }
}

/// What gets reported to the server. Band only — by construction there is no
/// birthdate here to leak.
struct AgeGateAttestation: Sendable, Equatable {
    let threshold: Int
    let meetsThreshold: Bool
    let lowerBound: Int?
    let upperBound: Int?
    let declaration: AgeDeclarationKind
    /// `declared_age_range` normally; `unavailable` when the gate could not run
    /// and policy let the member through anyway.
    let source: String
}

enum AgeGatePolicy {
    /// **A deliberate, reversible product decision — flag it to the commissioner.**
    ///
    /// `AgeRangeService` throws `.notAvailable` for reasons that have nothing to
    /// do with the member's age: the entitlement isn't provisioned yet, the
    /// device/region doesn't support the API, the system is wedged. Treating
    /// that as "under 18" would hard-stop every member on a device Apple hasn't
    /// enabled the API for — including, today, the Simulator.
    ///
    /// So an *unavailable* gate lets the member through with
    /// `source: "unavailable"` recorded, which is honest: the server can see
    /// exactly which accounts were never actually gated and re-gate them later.
    /// A *declined* gate and an *under-18* gate are hard stops regardless — those
    /// are answers, not failures.
    ///
    /// Flip this to `false` for a strict posture; it is a one-line change and
    /// nothing else needs to move.
    static let allowWhenUnavailable = true
}

enum AgeGateService {

    /// Interpret Apple's response against the 18+ threshold.
    ///
    /// The band comes back split at the gate we asked about: an adult gets a
    /// lower bound at or above the threshold, a minor gets an upper bound below
    /// it. Anything that is not a positive answer is treated as not passing —
    /// an ambiguous band is not an adult.
    static func evaluate(
        _ response: AgeRangeService.Response,
        threshold: Int = FWBConfig.minimumAge
    ) -> AgeGateOutcome {
        switch response {
        case .declinedSharing:
            ageLog.notice("Age range declined by member")
            return .blocked(reason: .declined)

        case .sharing(let range):
            let kind = declarationKind(range.ageRangeDeclaration)
            let passes = (range.lowerBound ?? -1) >= threshold
            ageLog.notice("Age range shared: lower=\(range.lowerBound ?? -1) upper=\(range.upperBound ?? -1) passes=\(passes)")
            guard passes else { return .blocked(reason: .underAge) }
            return .passed(AgeGateAttestation(
                threshold: threshold,
                meetsThreshold: true,
                lowerBound: range.lowerBound,
                upperBound: range.upperBound,
                declaration: kind,
                source: "declared_age_range"))

        // `Response` is a resilient enum from a system framework, so it can grow
        // cases this build has never heard of. Treating an unrecognised one as
        // "could not run" (rather than as a pass or a hard stop) is the only safe
        // reading: we did not get an answer we understand.
        @unknown default:
            ageLog.error("Unknown AgeRangeService.Response case")
            return .unavailable(message: "Age verification returned something this version doesn't understand.")
        }
    }

    /// Turn a thrown error into an outcome. `.notAvailable` and `.invalidRequest`
    /// are both "the gate could not run", not "the member is a minor".
    static func evaluate(error: Error, threshold: Int = FWBConfig.minimumAge) -> AgeGateOutcome {
        ageLog.error("Age range request failed: \(String(describing: error))")
        if let serviceError = error as? AgeRangeService.Error {
            switch serviceError {
            case .notAvailable:
                return .unavailable(message: "Age verification isn't available on this device.")
            case .invalidRequest:
                return .unavailable(message: "Age verification couldn't be started.")
            @unknown default:
                return .unavailable(message: "Age verification isn't available right now.")
            }
        }
        return .unavailable(message: error.localizedDescription)
    }

    /// The attestation to report when the gate could not run and policy allowed
    /// the member through anyway. Recorded rather than skipped, precisely so
    /// these accounts are findable.
    static func unavailableAttestation(threshold: Int = FWBConfig.minimumAge) -> AgeGateAttestation {
        AgeGateAttestation(
            threshold: threshold,
            meetsThreshold: false,
            lowerBound: nil,
            upperBound: nil,
            declaration: .unspecified,
            source: "unavailable")
    }

    private static func declarationKind(_ declaration: AgeRangeService.AgeRangeDeclaration?) -> AgeDeclarationKind {
        guard let declaration else { return .unspecified }
        // `.confirmed` (a verified rather than declared range) only exists from
        // iOS 26.5; the deployment target is 26.0, so it has to be probed.
        if #available(iOS 26.5, *), declaration == .confirmed { return .confirmed }
        switch declaration {
        case .selfDeclared:     return .selfDeclared
        case .guardianDeclared: return .guardianDeclared
        // The remaining cases are the 26.2-era `…Checked` variants, all since
        // deprecated in favour of `.confirmed`, plus whatever Apple adds next.
        default:                return .unspecified
        }
    }
}
