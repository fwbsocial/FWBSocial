import DeclaredAgeRange
import SwiftUI

// MARK: - SDK concurrency gap
//
// `DeclaredAgeRangeAction.callAsFunction` is `@concurrent` — it hops off the
// caller's actor — but the action type itself is not `Sendable`. Under this
// target's strict-concurrency settings that combination is a hard error at every
// call site, including the one Apple's own documentation shows:
//
//     let response = try await requestAgeRange(ageGates: 18)
//
// The type is an opaque, immutable handle read out of the SwiftUI environment;
// there is no mutable state in it to race on, and being called across a hop is
// its entire purpose. `@retroactive` because the conformance belongs to Apple —
// **delete this the moment DeclaredAgeRange ships its own `Sendable`
// conformance**, at which point the compiler will flag the duplicate.
extension DeclaredAgeRangeAction: @retroactive @unchecked Sendable {}

// MARK: - Onboarding gate
//
// A full-screen cover over the whole app, shown after the first successful
// authentication and dismissed only when both gates are satisfied
// (PLAN.md §6.1 / §6.3, commissioner Q16):
//
//   1. Terms — EULA (with the zero-tolerance clause), privacy policy, community
//      guidelines. Recorded against a *version*, not a boolean.
//   2. Age — the system Declared Age Range check at 18. A declared minor or a
//      refusal to share is a hard stop.
//
// It is `.interactiveDismissDisabled` for the obvious reason: a gate you can
// swipe away is not a gate.

struct OnboardingGateView: View {
    @Environment(AuthService.self) private var auth
    @Environment(OnboardingService.self) private var onboarding

    var body: some View {
        NavigationStack {
            Group {
                if let reason = onboarding.ageGateBlock {
                    AgeGateBlockedView(reason: reason)
                } else if onboarding.needsTermsAcceptance {
                    TermsAcceptanceView()
                } else if onboarding.needsAgeGate {
                    AgeGateView()
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Colors.background)
        }
        .interactiveDismissDisabled()
    }
}

// MARK: - Terms

struct TermsAcceptanceView: View {
    @Environment(AuthService.self) private var auth
    @Environment(OnboardingService.self) private var onboarding

    @State private var isWorking = false
    @State private var accepted = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                SectionHeader(
                    title: "Before you start",
                    subtitle: "A few things everyone agrees to.",
                    eyebrow: "fwb social")

                // PLACEHOLDER TEXT. PLAN.md Phase 3 requires the real documents
                // hosted at fwb.events before this ships — the acceptance row is
                // a claim about a specific text, so the text has to exist. The
                // links below already point at their final URLs; `fwb-web` is a
                // separate deliverable and is not deployed yet.
                FWBCard {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        Label("Zero tolerance for abuse", systemImage: "hand.raised.fill")
                            .font(Theme.Typography.rowTitle)
                        Text("There is no tolerance for objectionable content or abusive members. Anything you post to a channel or announcement can be reported, reviewed and removed, and accounts that break the guidelines are suspended.")
                            .font(Theme.Typography.preview)
                            .foregroundStyle(.secondary)
                    }
                }

                FWBCard {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        Label("What we can and can't see", systemImage: "lock.shield")
                            .font(Theme.Typography.rowTitle)
                        Text("Private chat is end-to-end encrypted — we can't read it, and we never scan it. We do hold conversation metadata: who messaged whom, when, and from which device. Forum posts and announcements are stored in plain text and are fully moderated.")
                            .font(Theme.Typography.preview)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Link(destination: FWBConfig.termsURL) {
                        Label("Terms of use", systemImage: "arrow.up.right.square")
                    }
                    Link(destination: FWBConfig.privacyURL) {
                        Label("Privacy policy", systemImage: "arrow.up.right.square")
                    }
                    Link(destination: FWBConfig.guidelinesURL) {
                        Label("Community guidelines", systemImage: "arrow.up.right.square")
                    }
                }
                .font(Theme.Typography.preview)
                .tint(Theme.Colors.brand)

                FormErrorText(message: errorMessage)

                Toggle(isOn: $accepted) {
                    Text("I've read and accept the terms, privacy policy and community guidelines.")
                        .font(Theme.Typography.preview)
                }
                .tint(Theme.Colors.brand)
                .padding(.top, Theme.Spacing.sm)
                .accessibilityIdentifier("onboarding.acceptToggle")

                Button {
                    accept()
                } label: {
                    if isWorking { ProgressView().tint(Theme.Colors.onBrand) } else { Text("Continue") }
                }
                .buttonStyle(FWBPrimaryButtonStyle())
                .disabled(!accepted || isWorking)
                .accessibilityIdentifier("onboarding.continue")

                Button("Sign out") { AuthService.shared.signOut() }
                    .font(Theme.Typography.preview)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .padding(Theme.Spacing.xl)
        }
        .navigationTitle("Terms")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func accept() {
        guard let user = auth.user else { return }
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await onboarding.acceptTerms(for: user)
            } catch {
                // A 409 means the hosted text moved on and this build is showing
                // the old version — an "update the app" problem, not a retry.
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}

// MARK: - Age gate

struct AgeGateView: View {
    @Environment(AuthService.self) private var auth
    @Environment(OnboardingService.self) private var onboarding

    // The SwiftUI front end for `AgeRangeService.requestAgeRange(ageGates:in:)`.
    // Using the environment action rather than the service call directly means
    // the system sheet gets presented from the right view controller without the
    // app having to go hunting for one.
    @Environment(\.requestAgeRange) private var requestAgeRange

    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                SectionHeader(
                    title: "Confirm your age",
                    subtitle: "fwb social is for members \(FWBConfig.minimumAge) and over.",
                    eyebrow: "One more thing")

                FWBCard {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        Label("We don't ask for your birthday", systemImage: "checkmark.seal")
                            .font(Theme.Typography.rowTitle)
                        // This is the honest description of what the API does,
                        // and it's worth saying plainly: the app receives a
                        // yes/no band around 18 and nothing else.
                        Text("Your device answers a single question — whether you're over \(FWBConfig.minimumAge) — using the age range already set up on your Apple Account. We never see your date of birth, and there's nothing else for us to store.")
                            .font(Theme.Typography.preview)
                            .foregroundStyle(.secondary)
                    }
                }

                FormErrorText(message: errorMessage)

                Button {
                    runGate()
                } label: {
                    if isWorking { ProgressView().tint(Theme.Colors.onBrand) } else { Text("Confirm my age") }
                }
                .buttonStyle(FWBPrimaryButtonStyle())
                .disabled(isWorking)
                .accessibilityIdentifier("onboarding.confirmAge")

                Button("Sign out") { AuthService.shared.signOut() }
                    .font(Theme.Typography.preview)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .padding(Theme.Spacing.xl)
        }
        .navigationTitle("Age check")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func runGate() {
        guard let user = auth.user else { return }
        isWorking = true
        errorMessage = nil
        Task {
            let outcome: AgeGateOutcome
            do {
                // Three thresholds, so Apple's answer maps onto the server's
                // bands (under_13 / 13_to_15 / 16_to_17 / 18_or_over) exactly
                // instead of forcing the client to invent one.
                let gates = AgeGateService.gates
                let response = try await requestAgeRange(ageGates: gates.0, gates.1, gates.2)
                outcome = AgeGateService.evaluate(response)
            } catch {
                outcome = AgeGateService.evaluate(error: error)
            }
            let proceeded = await onboarding.applyAgeGate(outcome, for: user)
            if !proceeded, onboarding.ageGateBlock == nil {
                // Prefer whatever the server said. "Check your connection" is only
                // right for the offline case, and this gate is the very first
                // screen a new member meets — sending them to look at their Wi-Fi
                // when the server has actually explained itself wastes the one
                // moment they are most likely to give up in.
                errorMessage = onboarding.lastAgeReportError?.fwbMessage
                    ?? "We couldn't record that — check your connection and try again."
            }
            isWorking = false
        }
    }
}

// MARK: - Hard stop

/// The end of the road. No retry button, no "are you sure" — a declared minor
/// and a refusal to answer both terminate here, and the only ways out are
/// signing out or deleting the account.
struct AgeGateBlockedView: View {
    let reason: AgeGateOutcome.BlockReason

    @State private var isDeleting = false
    @State private var showDeleteConfirm = false
    @State private var errorMessage: String?

    private var headline: String {
        switch reason {
        case .underAge: return "You need to be \(FWBConfig.minimumAge)"
        case .declined: return "We need an age check"
        }
    }

    private var explanation: String {
        switch reason {
        case .underAge:
            return "fwb social is an adults-only community, so we can't give you access. Nothing about your date of birth was shared with us."
        case .declined:
            return "We can't let anyone in without confirming they're \(FWBConfig.minimumAge) or over. If you'd like to continue, sign out and start again — you can share your age range from your Apple Account settings."
        }
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Spacer()

            Image(systemName: "hand.raised.fill")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Theme.Colors.caution)

            VStack(spacing: Theme.Spacing.md) {
                Text(headline)
                    .font(Theme.Typography.title)
                    .multilineTextAlignment(.center)
                Text(explanation)
                    .font(Theme.Typography.preview)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Theme.Spacing.xl)

            FormErrorText(message: errorMessage)
                .padding(.horizontal, Theme.Spacing.xl)

            Spacer()

            VStack(spacing: Theme.Spacing.md) {
                Button("Sign out") { AuthService.shared.signOut() }
                    .buttonStyle(FWBSecondaryButtonStyle())

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    if isDeleting { ProgressView() } else { Text("Delete my account") }
                }
                .font(Theme.Typography.preview)
                .disabled(isDeleting)

                Text("Questions? \(FWBConfig.supportEmail)")
                    .font(Theme.Typography.micro)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("Delete your account?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete account", role: .destructive) { deleteAccount() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes your account and can't be undone.")
        }
    }

    private func deleteAccount() {
        isDeleting = true
        errorMessage = nil
        Task {
            do {
                try await AuthService.shared.deleteAccount()
            } catch {
                errorMessage = error.localizedDescription
            }
            isDeleting = false
        }
    }
}
