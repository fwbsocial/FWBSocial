import Foundation
import Observation
import OSLog

private let onboardingLog = Logger(subsystem: "events.fwb.social", category: "Onboarding")

// MARK: - Onboarding state
//
// Two gates stand between a freshly authenticated member and the app
// (PLAN.md §6.1 / §6.3, commissioner Q16):
//
//   1. **Terms acceptance** — the EULA with its zero-tolerance clause, plus the
//      privacy policy and community guidelines. Guideline 1.2 requires this at
//      signup, and the record must name a *version*: "did they accept the text
//      that had the zero-tolerance clause?" is the only question that ever gets
//      asked, and a boolean cannot answer it.
//
//   2. **The 18+ age gate** — Apple's Declared Age Range API. A declared minor
//      or a refusal to share is a hard stop, not a nag.
//
// State lives in two places on purpose. The server is authoritative
// (`fwb_user_agreements`), but its routes are **not deployed yet** — see
// `OnboardingAPI.swift`. So acceptance is also written to `UserDefaults`, keyed
// by user id *and* document version, and replayed to the server on every launch
// until it sticks. The failure mode that matters is a member who accepted the
// terms being asked again on every cold launch because the server 404s; the
// local record prevents that without pretending the server has the row.

@Observable
@MainActor
final class OnboardingService {

    static let shared = OnboardingService()

    /// True once `refresh(for:)` has run for the current user — the gate view
    /// waits for it so nobody sees a flash of the EULA they already accepted.
    private(set) var didLoad = false

    /// The member still owes us an acceptance of the current document version.
    private(set) var needsTermsAcceptance = false

    /// The age gate has not produced a usable verdict yet.
    private(set) var needsAgeGate = false

    /// Set when the gate said no. The blocking screen reads this.
    private(set) var ageGateBlock: AgeGateOutcome.BlockReason?

    /// True when the server has no route for these records yet, so the app is
    /// running on local state alone. Surfaced in Settings → About rather than
    /// hidden, because "the server has no record of this acceptance" is exactly
    /// the sort of thing that should not be silent.
    private(set) var isRunningOnLocalRecordOnly = false

    /// Nothing left to ask, and nothing blocking.
    var isComplete: Bool { !needsTermsAcceptance && !needsAgeGate && ageGateBlock == nil }

    /// The member is barred from the app entirely.
    var isBlocked: Bool { ageGateBlock != nil }

    private let defaults = UserDefaults.standard
    private let api = APIClient.shared

    private init() {}

    // MARK: - Local keys

    private func termsKey(_ userId: String) -> String {
        "fwb.onboarding.terms.\(userId).\(FWBConfig.agreementsVersion)"
    }

    private func ageKey(_ userId: String) -> String {
        "fwb.onboarding.age.\(userId)"
    }

    /// Set when the attestation itself is recorded locally but has never been
    /// accepted by the server; drives the replay on the next launch.
    private func pendingSyncKey(_ userId: String) -> String {
        "fwb.onboarding.pendingSync.\(userId)"
    }

    // MARK: - Lifecycle

    /// Work out what the current member still owes. Cheap and idempotent; safe
    /// to call on every launch and after every sign-in.
    func refresh(for user: AuthUser?) async {
        guard let user else { reset(); return }
        let userId = user.id

        let acceptedLocally = defaults.bool(forKey: termsKey(userId))
        let agePassedLocally = defaults.bool(forKey: ageKey(userId))

        // Ask the server what it has. `nil` means the route isn't deployed —
        // which is NOT the same as "accepted nothing", and must not be read as
        // an unaccepted EULA.
        var acceptedOnServer: Bool?
        do {
            if let records = try await api.fetchAgreements() {
                isRunningOnLocalRecordOnly = false
                acceptedOnServer = records.contains {
                    $0.doc == AgreementDoc.eula.rawValue && $0.version == FWBConfig.agreementsVersion
                }
            } else {
                isRunningOnLocalRecordOnly = true
            }
        } catch {
            // Offline or a server error: fall back to the local record rather
            // than blocking a member who already accepted.
            onboardingLog.debug("Agreement fetch failed: \(error.localizedDescription)")
            isRunningOnLocalRecordOnly = true
        }

        needsTermsAcceptance = !(acceptedOnServer ?? acceptedLocally)
        needsAgeGate = !agePassedLocally
        ageGateBlock = nil
        didLoad = true

        if defaults.bool(forKey: pendingSyncKey(userId)) {
            await replayPendingSync(userId: userId)
        }
    }

    /// Clear in-memory state on sign-out. Local acceptance records are keyed by
    /// user id and deliberately survive — signing out and back in is not a
    /// reason to re-accept the same version of the same document.
    func reset() {
        didLoad = false
        needsTermsAcceptance = false
        needsAgeGate = false
        ageGateBlock = nil
        isRunningOnLocalRecordOnly = false
    }

    /// Drop every local record for a user. Called on account deletion so a
    /// re-registration on the same device starts genuinely clean.
    func forgetLocalState(for userId: String?) {
        guard let userId else { return }
        defaults.removeObject(forKey: ageKey(userId))
        defaults.removeObject(forKey: pendingSyncKey(userId))
        // The terms key is version-scoped, so only the current version can be
        // named here. An older version's leftover key is harmless — it can never
        // satisfy the current-version check.
        defaults.removeObject(forKey: termsKey(userId))
    }

    // MARK: - Terms

    /// Record acceptance of the EULA, privacy policy and community guidelines.
    ///
    /// Local first, deliberately: the member tapped Accept, and their experience
    /// must not depend on a route that may not exist. The server write follows
    /// and is retried on the next launch if it doesn't land.
    func acceptTerms(for user: AuthUser) async {
        let userId = user.id
        defaults.set(true, forKey: termsKey(userId))
        needsTermsAcceptance = false

        var allRecorded = true
        for doc in AgreementDoc.allCases {
            do {
                let result = try await api.acceptAgreement(doc: doc, version: FWBConfig.agreementsVersion)
                if result == .routeNotDeployed {
                    allRecorded = false
                    isRunningOnLocalRecordOnly = true
                }
            } catch {
                onboardingLog.error("Agreement '\(doc.rawValue)' not recorded: \(error.localizedDescription)")
                allRecorded = false
            }
        }
        defaults.set(!allRecorded, forKey: pendingSyncKey(userId))
    }

    // MARK: - Age gate

    /// Apply the gate's verdict. Returns `true` when the member may proceed.
    @discardableResult
    func applyAgeGate(_ outcome: AgeGateOutcome, for user: AuthUser) async -> Bool {
        let userId = user.id

        switch outcome {
        case .passed(let attestation):
            defaults.set(true, forKey: ageKey(userId))
            needsAgeGate = false
            ageGateBlock = nil
            await report(attestation, userId: userId)
            return true

        case .blocked(let reason):
            // Not persisted as a pass, and not persisted as a permanent local
            // block either — the authority for "this member is a minor" belongs
            // on the server, and a local flag would be both unenforceable and
            // trivially cleared by a reinstall.
            ageGateBlock = reason
            needsAgeGate = true
            await report(
                AgeGateAttestation(
                    threshold: FWBConfig.minimumAge,
                    meetsThreshold: false,
                    lowerBound: nil,
                    upperBound: nil,
                    declaration: .unspecified,
                    source: reason == .declined ? "declined" : "declared_age_range"),
                userId: userId)
            return false

        case .unavailable(let message):
            onboardingLog.notice("Age gate unavailable: \(message)")
            guard AgeGatePolicy.allowWhenUnavailable else {
                ageGateBlock = .declined
                needsAgeGate = true
                return false
            }
            defaults.set(true, forKey: ageKey(userId))
            needsAgeGate = false
            ageGateBlock = nil
            await report(AgeGateService.unavailableAttestation(), userId: userId)
            return true
        }
    }

    private func report(_ attestation: AgeGateAttestation, userId: String) async {
        do {
            let result = try await api.reportAgeAttestation(
                threshold: attestation.threshold,
                meetsThreshold: attestation.meetsThreshold,
                lowerBound: attestation.lowerBound,
                upperBound: attestation.upperBound,
                declaration: attestation.declaration.rawValue,
                source: attestation.source)
            if result == .routeNotDeployed {
                isRunningOnLocalRecordOnly = true
                defaults.set(true, forKey: pendingSyncKey(userId))
            }
        } catch {
            onboardingLog.error("Age attestation not recorded: \(error.localizedDescription)")
            defaults.set(true, forKey: pendingSyncKey(userId))
        }
    }

    // MARK: - Replay

    /// Re-send whatever the server never accepted. Best effort, silent, and
    /// idempotent on the server side (one row per user/doc/version).
    private func replayPendingSync(userId: String) async {
        guard defaults.bool(forKey: termsKey(userId)) else { return }
        var stillPending = false
        for doc in AgreementDoc.allCases {
            do {
                if try await api.acceptAgreement(doc: doc, version: FWBConfig.agreementsVersion) == .routeNotDeployed {
                    stillPending = true
                }
            } catch {
                stillPending = true
            }
        }
        defaults.set(stillPending, forKey: pendingSyncKey(userId))
        if stillPending { isRunningOnLocalRecordOnly = true }
    }
}
