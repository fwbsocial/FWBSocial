import SwiftUI

// MARK: - Luma email linking
//
// PLAN.md §4.5.3, and R9. The problem this solves is not an edge case:
//
// Sign in with Apple members who choose "Hide My Email" get a
// `@privaterelay.appleid.com` address, which **never appears on a Luma guest list**.
// Under pure email matching, every privacy-conscious SIWA member is unvettable and
// invisible to friending — and SIWA is mandatory under Guideline 4.8. The same
// failure hits the far commoner "I RSVP'd with my personal address and signed up
// with my work one".
//
// So the member tells us which address they use on Luma, and proves they control it
// with a six-digit code.
//
// # Two rules this UI must not break
//
//  1. **Self-claim never vets.** Verifying an address proves control of the address;
//     it does not grant access. Vetting still needs a real guest row carrying a
//     check-in, and the server backfills only what the guest data supports. The copy
//     says "we'll match you" rather than "you'll get in", because the second would
//     be a promise the server does not make.
//
//  2. **We only ever mail an address the member typed here.** `fwb_luma_guests.email`
//     is match-only and no code path may reach the mailer with it — that is a Luma
//     ToS boundary (R13), and emailing guests who never consented can suspend the
//     calendar's Plus account.

struct LumaEmailLinkView: View {
    let status: LumaEmailStatusDTO?
    var onChange: (() async -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var code = ""
    @State private var didSendCode = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var verified = false

    var body: some View {
        Form {
            Section {
                Text(explanation)
                    .font(Theme.Typography.preview)
            } header: {
                Text("Why we're asking")
            }

            if verified || status?.verified == true {
                Section {
                    Label(status?.lumaEmail ?? email, systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Theme.Colors.positive)
                } header: {
                    Text("Linked address")
                } footer: {
                    Text("We'll match you to check-ins on this address from now on, including events you've already been to.")
                }
            } else {
                Section {
                    TextField("you@example.com", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(didSendCode)
                        .accessibilityIdentifier("luma.email")

                    if didSendCode {
                        TextField("6-digit code", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .monospaced()
                            .accessibilityIdentifier("luma.code")
                    }
                } header: {
                    Text("Your Luma email")
                } footer: {
                    Text(didSendCode
                         ? "We sent a code to \(email). It's good for 10 minutes."
                         : "The address you RSVP with on Luma. We'll send it a code — this is the only address we ever email.")
                }

                Section {
                    if didSendCode {
                        Button("Verify") { Task { await verify() } }
                            .disabled(code.count < 6 || isWorking)
                            .accessibilityIdentifier("luma.verify")
                        Button("Use a different address") {
                            didSendCode = false
                            code = ""
                            errorMessage = nil
                        }
                        .foregroundStyle(.secondary)
                    } else {
                        Button("Send code") { Task { await sendCode() } }
                            .disabled(!isPlausibleEmail || isWorking)
                            .accessibilityIdentifier("luma.sendCode")
                    }
                }
            }

            if let errorMessage {
                Section { FormErrorText(message: errorMessage) }
            }
        }
        .navigationTitle("Luma email")
        .navigationBarTitleDisplayMode(.inline)
        .task { email = status?.lumaEmail ?? "" }
    }

    private var explanation: String {
        if status?.promptRequired == true {
            // The relay-address case, where this is not optional in practice.
            return "You signed in with Apple's private email relay, so your address can't appear on a Luma guest list. Tell us which address you use on Luma and we'll be able to match your check-ins."
        }
        return "If you RSVP on Luma with a different address than you signed up with, tell us which one and we'll match your check-ins to it."
    }

    /// Deliberately loose. The server is the authority on whether an address is
    /// deliverable, and a strict client-side regex is a good way to reject a valid
    /// address nobody anticipated.
    private var isPlausibleEmail: Bool {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("@") && trimmed.contains(".") && trimmed.count >= 6
    }

    private func sendCode() async {
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        do {
            try await EventsAPI.requestLumaEmailCode(email.trimmingCharacters(in: .whitespaces))
            didSendCode = true
        } catch let APIError.rateLimited(retryAfter) {
            let wait = retryAfter.map { "\($0 / 60) minutes" } ?? "a few minutes"
            errorMessage = "Too many codes requested. Try again in \(wait)."
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't send that code."
        }
    }

    private func verify() async {
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        do {
            _ = try await EventsAPI.verifyLumaEmail(email.trimmingCharacters(in: .whitespaces), code: code)
            verified = true
            await onChange?()
            // The server re-scans historical guests on verification and backfills
            // attendance, so the member's own record may have changed underneath
            // them — reload it rather than showing a stale vetting state.
            await AuthService.shared.reloadUser()
        } catch {
            // One message for a wrong code and an expired one: distinguishing them
            // tells an attacker which half of a guess was right.
            errorMessage = "That code didn't match. Check it, or request a new one."
        }
    }
}

// MARK: - Home / Events card

/// The persistent prompt (§4.5.3). Mandatory-with-explanation for a relay address,
/// a quiet card otherwise.
struct LumaEmailCard: View {
    let status: LumaEmailStatusDTO
    var onChange: (() async -> Void)?

    var body: some View {
        FWBCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: status.promptRequired ? "exclamationmark.circle.fill" : "envelope.badge")
                        .foregroundStyle(status.promptRequired ? Theme.Colors.caution : Theme.Colors.brand)
                    Text(status.promptRequired ? "We can't match you yet" : "What email do you use on Luma?")
                        .font(Theme.Typography.rowTitle)
                }

                Text(status.promptRequired
                     ? "Your Apple private relay address can't appear on a guest list, so we can't match your check-ins to it."
                     : "If you RSVP with a different address than you signed up with, link it so we can match your check-ins.")
                    .font(Theme.Typography.preview)
                    .foregroundStyle(.secondary)

                NavigationLink {
                    LumaEmailLinkView(status: status, onChange: onChange)
                } label: {
                    Text("Link my Luma email")
                        .font(Theme.Typography.caption.weight(.semibold))
                }
                .accessibilityIdentifier("luma.card.link")
            }
        }
    }
}
