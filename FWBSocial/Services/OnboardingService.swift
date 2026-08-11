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
//      signup, and the record names a *version*: "did they accept the text that
//      had the zero-tolerance clause?" is the only question that ever gets
//      asked, and a boolean cannot answer it.
//
//   2. **The 18+ age gate** — Apple's Declared Age Range API. A declared minor
//      or a refusal to share is a hard stop, not a nag.
//
// **The server is the authority.** `GET /api/onboarding/status` answers both
// questions, and this class is mostly a cache of that answer. The one place it
// overrides the server is the unavailable-gate case: the server records
// `unknown`, which never satisfies `is_declared_adult`, so it would keep asking
// forever on a device where the API can't run. A local, per-user note suppresses
// the re-prompt without pretending the server said adult — the account stays
// visibly un-gated server-side, which is exactly what an audit needs.

@Observable
@MainActor
final class OnboardingService {

    static let shared = OnboardingService()

    /// True once `refresh(for:)` has run for the current user — the gate view
    /// waits for it so nobody sees a flash of the EULA they already accepted.
    private(set) var didLoad = false

    /// The member still owes an acceptance of the current document version.
    private(set) var needsTermsAcceptance = false

    /// The age gate has not produced a usable verdict yet.
    private(set) var needsAgeGate = false

    /// Set when the gate said no. The blocking screen reads this.
    private(set) var ageGateBlock: AgeGateOutcome.BlockReason?

    /// True when the server couldn't be reached or has no onboarding routes, so
    /// the app is running on local state alone. Surfaced in Settings rather than
    /// hidden — "the server has no record of your acceptance" should not be silent.
    private(set) var isRunningOnLocalRecordOnly = false

    /// The last status the server gave us, for anything that wants the detail.
    private(set) var status: OnboardingStatus?

    /// Nothing left to ask, and nothing blocking.
    var isComplete: Bool { !needsTermsAcceptance && !needsAgeGate && ageGateBlock == nil }

    /// The member is barred from the app entirely.
    var isBlocked: Bool { ageGateBlock != nil }

    private let defaults = UserDefaults.standard
    private let api = APIClient.shared

    private init() {}

    // MARK: - Local keys

    /// Local mirror of the acceptance, so a server that is briefly unreachable
    /// doesn't re-ask a member who already accepted this exact version.
    private func termsKey(_ userId: String) -> String {
        "fwb.onboarding.terms.\(userId).\(FWBConfig.agreementsVersion)"
    }

    /// Set only when the gate ran and could not answer, and policy let the
    /// member through. Never set for a pass — a pass is the server's to record.
    private func ageUnavailableKey(_ userId: String) -> String {
        "fwb.onboarding.ageUnavailable.\(userId)"
    }

    // MARK: - Lifecycle

    /// Work out what the current member still owes. Cheap and idempotent; safe
    /// to call on every launch and after every sign-in.
    func refresh(for user: AuthUser?) async {
        guard let user else { reset(); return }
        let userId = user.id

        do {
            if let remote = try await api.onboardingStatus() {
                status = remote
                isRunningOnLocalRecordOnly = false
                needsTermsAcceptance = !remote.acceptedAll
                needsAgeGate = remote.ageDeclarationRequired
                    && !defaults.bool(forKey: ageUnavailableKey(userId))
                ageGateBlock = nil
                didLoad = true
                return
            }
            // No onboarding routes at all — an older server.
            isRunningOnLocalRecordOnly = true
        } catch {
            onboardingLog.debug("Onboarding status fetch failed: \(error.localizedDescription)")
            isRunningOnLocalRecordOnly = true
        }

        // Offline / no routes: fall back to what this device remembers rather
        // than blocking a member who has already been through this.
        needsTermsAcceptance = !defaults.bool(forKey: termsKey(userId))
        needsAgeGate = !defaults.bool(forKey: ageUnavailableKey(userId))
        ageGateBlock = nil
        didLoad = true
    }

    /// Clear in-memory state on sign-out. Local records are keyed by user id and
    /// deliberately survive — signing out and back in is not a reason to
    /// re-accept the same version of the same document.
    func reset() {
        didLoad = false
        needsTermsAcceptance = false
        needsAgeGate = false
        ageGateBlock = nil
        isRunningOnLocalRecordOnly = false
        status = nil
    }

    /// Drop every local record for a user, so a re-registration on this device
    /// starts genuinely clean.
    func forgetLocalState(for userId: String?) {
        guard let userId else { return }
        defaults.removeObject(forKey: ageUnavailableKey(userId))
        // The terms key is version-scoped, so only the current version can be
        // named here. An older version's leftover key is harmless — it can never
        // satisfy the current-version check.
        defaults.removeObject(forKey: termsKey(userId))
    }

    // MARK: - Terms

    /// Accept the EULA, privacy policy and community guidelines in one step.
    ///
    /// The version this build displayed goes on the wire, and the server rejects
    /// it with a 409 if its own text has moved on — a stale build must not be
    /// able to record acceptance of text the member never saw. That surfaces as
    /// an error the member can act on ("update the app"), not a silent retry.
    func acceptTerms(for user: AuthUser) async throws {
        let userId = user.id
        do {
            if let remote = try await api.acceptAgreements(version: FWBConfig.agreementsVersion) {
                status = remote
                isRunningOnLocalRecordOnly = false
                needsTermsAcceptance = !remote.acceptedAll
                needsAgeGate = remote.ageDeclarationRequired
                    && !defaults.bool(forKey: ageUnavailableKey(userId))
                defaults.set(true, forKey: termsKey(userId))
                return
            }
            // Route missing: record locally so the member isn't asked forever,
            // and say so in Settings.
            isRunningOnLocalRecordOnly = true
            defaults.set(true, forKey: termsKey(userId))
            needsTermsAcceptance = false
        } catch is AgreementVersionConflictError {
            throw AgreementVersionConflictError(reason: nil)
        } catch {
            onboardingLog.error("Agreement acceptance failed: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Age gate

    /// Apply the gate's verdict, reporting the band to the server.
    /// Returns `true` when the member may proceed.
    @discardableResult
    func applyAgeGate(_ outcome: AgeGateOutcome, for user: AuthUser) async -> Bool {
        let userId = user.id

        switch outcome {
        case .passed(let band, let declaration):
            onboardingLog.notice("Age gate passed (\(band.rawValue), \(declaration.rawValue))")
            let recorded = await report(band)
            // The server is the authority on adulthood. If it couldn't be told,
            // don't fabricate a pass — but don't trap the member on the gate
            // screen over a network blip either; the next launch re-asks.
            needsAgeGate = !recorded
            ageGateBlock = nil
            return recorded

        case .blocked(let reason, let band):
            // Report before blocking: the server records the band and *then*
            // refuses, so re-running the flow doesn't hand a minor another go at
            // the dialog. That only works if the band actually reaches it.
            _ = await report(band)
            ageGateBlock = reason
            needsAgeGate = true
            return false

        case .unavailable(let message):
            onboardingLog.notice("Age gate unavailable: \(message)")
            // Recorded as `unknown`, which never satisfies `is_declared_adult` —
            // these accounts stay findable and re-gateable.
            _ = await report(.unknown)
            guard AgeGatePolicy.allowWhenUnavailable else {
                ageGateBlock = .declined
                needsAgeGate = true
                return false
            }
            defaults.set(true, forKey: ageUnavailableKey(userId))
            needsAgeGate = false
            ageGateBlock = nil
            return true
        }
    }

    /// Send the band. Returns whether the server accepted it.
    private func report(_ band: DeclaredAgeBand) async -> Bool {
        do {
            if let remote = try await api.declareAgeRange(band) {
                status = remote
                isRunningOnLocalRecordOnly = false
                return true
            }
            // Route missing.
            isRunningOnLocalRecordOnly = true
            return true
        } catch is DeclaredMinorError {
            // The refusal IS the server accepting the band — it recorded it and
            // then said no.
            return false
        } catch {
            onboardingLog.error("Age declaration not recorded: \(error.localizedDescription)")
            isRunningOnLocalRecordOnly = true
            return false
        }
    }
}
