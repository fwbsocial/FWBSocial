import AuthenticationServices
import SwiftUI
import OSLog

private let siwaLog = Logger(subsystem: "events.fwb.social", category: "SIWA")

// MARK: - Sign in with Apple
//
// Guideline 4.8 — ships day one (PLAN.md §6.1). `SignInWithAppleButton` is the
// SwiftUI front end for `ASAuthorizationController`/`ASAuthorizationAppleIDProvider`:
// same controller, same delegate flow, but Apple owns the button's appearance,
// which 4.8 also cares about.
//
// **The `authorizationCode` is the load-bearing part** (PLAN.md §3.1). The
// server exchanges it exactly once, at sign-in time, for the Apple refresh token
// that account deletion needs to call `POST https://appleid.apple.com/auth/revoke`.
// The code is single-use and short-lived, so there is no second chance to
// collect it: if it isn't forwarded here, that account's Apple grant can never
// be revoked — and that surfaces at the first App Review deletion test, by which
// point every existing SIWA account is affected.
//
// `fullName` arrives on the FIRST authorization only, and never again. It's
// forwarded for the display name; the server treats it as a label, not identity.
// The email is forwarded too and deliberately ignored server-side — it is
// attacker-controlled and is never used to select a row.

struct AppleSignInButton: View {
    /// Called with a friendly message when the flow fails for a reason worth
    /// showing. User-initiated cancellation never calls this.
    var onError: (String) -> Void
    /// Called after a successful sign-in.
    var onSuccess: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SignInWithAppleButton(.continue) { request in
            request.requestedScopes = [.fullName, .email]
        } onCompletion: { result in
            handle(result)
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: 50)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }

    private func handle(_ result: Result<ASAuthorization, any Error>) {
        switch result {
        case .failure(let error):
            // A cancel is not an error worth a banner — the member closed the
            // sheet on purpose.
            if let authError = error as? ASAuthorizationError, authError.code == .canceled { return }
            siwaLog.error("SIWA failed: \(String(describing: error))")
            onError("Apple couldn't complete that sign-in.")

        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                onError("Apple returned an unexpected credential.")
                return
            }
            guard let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8) else {
                onError("Apple didn't return an identity token.")
                return
            }
            let authorizationCode = credential.authorizationCode
                .flatMap { String(data: $0, encoding: .utf8) }
            if authorizationCode == nil {
                siwaLog.error("SIWA credential carried no authorizationCode — this account's Apple grant will be unrevocable (Guideline 5.1.1(v))")
            }

            let fullName = credential.fullName.flatMap { components -> String? in
                let formatted = PersonNameComponentsFormatter.localizedString(from: components, style: .default)
                return formatted.isEmpty ? nil : formatted
            }

            Task {
                do {
                    try await AuthService.shared.appleSignIn(
                        identityToken: identityToken,
                        authorizationCode: authorizationCode,
                        fullName: fullName,
                        email: credential.email)
                    onSuccess()
                } catch {
                    onError(error.localizedDescription)
                }
            }
        }
    }
}
