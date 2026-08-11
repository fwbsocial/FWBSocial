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
// What the API gives back is a *band*, never a birthdate: the app names up to
// three thresholds and receives a range whose bounds straddle them. Nothing else
// about the person's age is disclosed, and there is nothing else to store.
//
// **Three gates, not one.** fwb-server records one of `under_13`, `13_to_15`,
// `16_to_17`, `18_or_over` or `unknown`, so asking only about 18 would force
// every minor into a band the client had to invent. Asking at 13, 16 and 18
// makes Apple's answer map onto the server's enum exactly, with no guessing.
//
// Requires the `com.apple.developer.declared-age-range` entitlement
// (`FWBSocial.entitlements`) and the matching portal capability on App ID
// `events.fwb.social`. Without it, `AgeRangeService` throws `.notAvailable`.

/// The bands fwb-server's `DeclaredAgeRange` accepts, verbatim.
///
/// `unknown` is a real, distinct answer: asked, and the device declined or
/// couldn't say. It is not "never asked" (which the server models as nil), and
/// it is not a minor — but it is also not an adult, so the server keeps asking.
enum DeclaredAgeBand: String, Sendable, Equatable {
    case unknown
    case under13 = "under_13"
    case thirteenToFifteen = "13_to_15"
    case sixteenToSeventeen = "16_to_17"
    case eighteenOrOver = "18_or_over"

    var isAdult: Bool { self == .eighteenOrOver }
    var isMinor: Bool {
        switch self {
        case .under13, .thirteenToFifteen, .sixteenToSeventeen: return true
        case .eighteenOrOver, .unknown: return false
        }
    }
}

/// How the band was established. Kept for the log rather than the wire — the
/// server's contract takes the band alone — but the distinction is worth having
/// locally: a self-declaration is a weaker claim than a verified one.
enum AgeDeclarationKind: String, Sendable {
    case selfDeclared = "self_declared"
    case guardianDeclared = "guardian_declared"
    case confirmed = "confirmed"
    case unspecified = "unspecified"
}

/// The gate's verdict.
enum AgeGateOutcome: Sendable, Equatable {
    /// Declared 18 or over. Proceed.
    case passed(band: DeclaredAgeBand, declaration: AgeDeclarationKind)
    /// Declared under 18, or the member declined to share. Hard stop.
    case blocked(reason: BlockReason, band: DeclaredAgeBand)
    /// The API could not run at all — no entitlement, unsupported platform or
    /// region, or a system error. See `AgeGatePolicy.allowWhenUnavailable`.
    case unavailable(message: String)

    enum BlockReason: String, Sendable {
        case underAge = "under_age"
        case declined = "declined"
    }

    /// The band to report to the server, if there is one worth reporting.
    var reportableBand: DeclaredAgeBand? {
        switch self {
        case .passed(let band, _):   return band
        case .blocked(_, let band):  return band
        case .unavailable:           return .unknown
        }
    }
}

enum AgeGatePolicy {
    /// **A deliberate, reversible product decision — flag it to the commissioner.**
    ///
    /// `AgeRangeService` throws `.notAvailable` for reasons that have nothing to
    /// do with the member's age: the entitlement isn't provisioned yet, the
    /// device or region doesn't support the API, the system is wedged. Treating
    /// that as "under 18" would hard-stop every member on a device Apple hasn't
    /// enabled the API for — including, today, the Simulator.
    ///
    /// So an *unavailable* gate lets the member into the app while reporting the
    /// band as `unknown`, which is the honest record: the server can list every
    /// account that was never actually gated and re-gate them later, because
    /// `unknown` never satisfies `is_declared_adult`.
    ///
    /// A *declined* gate and an *under-18* gate are hard stops regardless —
    /// those are answers, not failures.
    ///
    /// Flip this to `false` for a strict posture; nothing else needs to move.
    static let allowWhenUnavailable = true
}

enum AgeGateService {

    /// The thresholds to ask about, chosen to line up with the server's bands.
    static let gates = (13, 16, 18)

    /// Interpret Apple's response.
    static func evaluate(_ response: AgeRangeService.Response) -> AgeGateOutcome {
        switch response {
        case .declinedSharing:
            ageLog.notice("Age range declined by member")
            return .blocked(reason: .declined, band: .unknown)

        case .sharing(let range):
            let kind = declarationKind(range.ageRangeDeclaration)
            let band = band(lower: range.lowerBound, upper: range.upperBound)
            ageLog.notice("Age range shared: lower=\(range.lowerBound ?? -1) upper=\(range.upperBound ?? -1) band=\(band.rawValue)")

            if band.isAdult { return .passed(band: band, declaration: kind) }
            if band.isMinor { return .blocked(reason: .underAge, band: band) }
            // A band we can't place is not an adult. Treated as `unknown` and
            // routed through the unavailable path so policy — not an accident of
            // parsing — decides what happens.
            return .unavailable(message: "Your device didn't give us a clear answer.")

        // `Response` is a resilient enum from a system framework and can grow
        // cases this build has never heard of. An unrecognised one is "no answer
        // we understand", which is neither a pass nor a hard stop.
        @unknown default:
            ageLog.error("Unknown AgeRangeService.Response case")
            return .unavailable(message: "Age verification returned something this version doesn't understand.")
        }
    }

    /// Turn a thrown error into an outcome. `.notAvailable` and `.invalidRequest`
    /// both mean "the gate could not run", not "the member is a minor".
    static func evaluate(error: Error) -> AgeGateOutcome {
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

    /// Map Apple's bounds onto the server's band.
    ///
    /// With gates at 13/16/18 the answer is one of four disjoint ranges, so the
    /// lower bound alone decides it in the normal case. The upper-bound branch
    /// covers the open-below range (no lower bound at all), which is how "under
    /// the lowest gate" comes back.
    static func band(lower: Int?, upper: Int?) -> DeclaredAgeBand {
        if let lower {
            if lower >= 18 { return .eighteenOrOver }
            if lower >= 16 { return .sixteenToSeventeen }
            if lower >= 13 { return .thirteenToFifteen }
            return .under13
        }
        if let upper {
            if upper < 13 { return .under13 }
            if upper < 16 { return .thirteenToFifteen }
            if upper < 18 { return .sixteenToSeventeen }
            return .eighteenOrOver
        }
        return .unknown
    }

    private static func declarationKind(_ declaration: AgeRangeService.AgeRangeDeclaration?) -> AgeDeclarationKind {
        guard let declaration else { return .unspecified }
        // `.confirmed` (a verified rather than declared range) only exists from
        // iOS 26.5; the deployment target is 26.0, so it has to be probed.
        if #available(iOS 26.5, *), declaration == .confirmed { return .confirmed }
        switch declaration {
        case .selfDeclared:     return .selfDeclared
        case .guardianDeclared: return .guardianDeclared
        // The rest are the 26.2-era `…Checked` variants, since deprecated in
        // favour of `.confirmed`, plus whatever Apple adds next.
        default:                return .unspecified
        }
    }
}
