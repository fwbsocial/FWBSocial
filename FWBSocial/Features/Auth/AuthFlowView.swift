import SwiftUI

// MARK: - Auth flow
//
// Presented as a sheet from anywhere that needs a signed-in member. The app
// itself is NOT behind this — the Home tab's announcements feed works signed out
// on purpose (PLAN.md §4.1 / §6.1: a members-only app behind a hard login wall
// is the classic Guideline 2.1 "unable to review" rejection).
//
// Brand text is always lowercase "fwb social" (owner directive 2026-08-10).
// Technical identifiers keep their normal casing; user-facing copy does not.

struct AuthFlowView: View {
    enum Destination: Hashable {
        case signIn
        case register
        case forgotPassword
    }

    @Environment(\.dismiss) private var dismiss
    @State private var path: [Destination] = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack(path: $path) {
            welcome
                .navigationDestination(for: Destination.self) { destination in
                    switch destination {
                    case .signIn:
                        SignInView(onForgotPassword: { path.append(.forgotPassword) })
                    case .register:
                        RegisterView()
                    case .forgotPassword:
                        ForgotPasswordView()
                    }
                }
        }
        .onChange(of: AuthService.shared.isSignedIn) { _, signedIn in
            if signedIn { dismiss() }
        }
    }

    // MARK: Welcome

    // The welcome column is vertically centred by its own spacers, which is right
    // until Dynamic Type makes it taller than the screen. At the accessibility
    // sizes the 46 pt Sue wordmark, the 64 pt mark, the subtitle, three buttons and
    // the legal line do not fit — and because this was a plain `VStack` with no
    // scroll view, the sign-in buttons ended up below the bezel with no way to
    // reach them. The app's very first screen, unusable, at a setting Apple
    // themselves test with.
    //
    // `ViewThatFits` keeps the centred composition wherever it still fits and only
    // falls back to scrolling when it genuinely cannot — which is better than
    // making every member scroll a screen that fits.
    private var welcome: some View {
        ViewThatFits(in: .vertical) {
            welcomeColumn
            ScrollView { welcomeColumn }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.background)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Not now") { dismiss() }
            }
        }
    }

    private var welcomeColumn: some View {
        VStack(spacing: 0) {
            Spacer(minLength: Theme.Spacing.xxl)

            VStack(spacing: Theme.Spacing.md) {
                Image(systemName: "person.2.circle.fill")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(Theme.Colors.brandGradient)

                Text("fwb social")
                    .font(Theme.Typography.Sue.hero)

                Text("Announcements, channels, events and private chat for members.")
                    .font(Theme.Typography.preview)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.xl)
            }

            Spacer()

            VStack(spacing: Theme.Spacing.md) {
                AppleSignInButton(onError: { errorMessage = $0 })

                Button("Continue with email") { path.append(.signIn) }
                    .buttonStyle(FWBSecondaryButtonStyle())
                    .accessibilityIdentifier("auth.continueWithEmail")

                Button("Create an account") { path.append(.register) }
                    .accessibilityIdentifier("auth.createAccount")
                    .font(Theme.Typography.preview)
                    .foregroundStyle(Theme.Colors.brand)
                    .padding(.top, Theme.Spacing.xs)

                FormErrorText(message: errorMessage)

                Text("You must be \(FWBConfig.minimumAge) or over. Creating an account means accepting our terms and community guidelines.")
                    .font(Theme.Typography.micro)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, Theme.Spacing.sm)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.xxl)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Sign in

struct SignInView: View {
    var onForgotPassword: () -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    private var canSubmit: Bool {
        !email.trimmed.isEmpty && password.count >= 1 && !isWorking
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                SectionHeader(title: "Sign in", subtitle: "Welcome back to fwb social.")
                    .padding(.bottom, Theme.Spacing.sm)

                FWBTextField(title: "Email", text: $email,
                             systemImage: "envelope",
                             contentType: .emailAddress,
                             keyboard: .emailAddress) { focus = .password }
                    .focused($focus, equals: .email)

                FWBTextField(title: "Password", text: $password,
                             systemImage: "lock",
                             contentType: .password,
                             isSecure: true,
                             submitLabel: .go) { submit() }
                    .focused($focus, equals: .password)

                FormErrorText(message: errorMessage)

                Button {
                    submit()
                } label: {
                    if isWorking { ProgressView().tint(Theme.Colors.onBrand) } else { Text("Sign in") }
                }
                .buttonStyle(FWBPrimaryButtonStyle())
                .disabled(!canSubmit)
                .accessibilityIdentifier("signIn.submit")

                Button("Forgot your password?", action: onForgotPassword)
                    .font(Theme.Typography.preview)
                    .foregroundStyle(Theme.Colors.brand)
                    .frame(maxWidth: .infinity)
            }
            .padding(Theme.Spacing.xl)
        }
        .fwbDismissKeyboardOnTap()
        .background(Theme.Colors.background)
        .navigationTitle("Sign in")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focus = .email }
    }

    private func submit() {
        guard canSubmit else { return }
        fwbDismissKeyboard()
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await AuthService.shared.login(email: email.trimmed, password: password)
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}

// MARK: - Register

struct RegisterView: View {
    @State private var displayName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var focus: Field?

    private enum Field { case name, email, password }

    /// Mirrors the server's own validation so the failure is local and instant
    /// rather than a round trip: display name 1–50, password ≥ 8.
    private var canSubmit: Bool {
        !displayName.trimmed.isEmpty
            && displayName.trimmed.count <= 50
            && email.trimmed.contains("@")
            && password.count >= 8
            && !isWorking
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                SectionHeader(title: "Create account", subtitle: "Join fwb social.")
                    .padding(.bottom, Theme.Spacing.sm)

                FWBTextField(title: "Display name", text: $displayName,
                             systemImage: "person",
                             contentType: .name) { focus = .email }
                    .focused($focus, equals: .name)
                    .accessibilityIdentifier("register.displayName")

                FWBTextField(title: "Email", text: $email,
                             systemImage: "envelope",
                             contentType: .emailAddress,
                             keyboard: .emailAddress) { focus = .password }
                    .focused($focus, equals: .email)
                    .accessibilityIdentifier("register.email")

                FWBTextField(title: "Password", text: $password,
                             systemImage: "lock",
                             contentType: .newPassword,
                             isSecure: true,
                             submitLabel: .go) { submit() }
                    .focused($focus, equals: .password)
                    .accessibilityIdentifier("register.password")

                Text("At least eight characters.")
                    .font(Theme.Typography.micro)
                    .foregroundStyle(.secondary)

                FormErrorText(message: errorMessage)

                Button {
                    submit()
                } label: {
                    if isWorking { ProgressView().tint(Theme.Colors.onBrand) } else { Text("Create account") }
                }
                .buttonStyle(FWBPrimaryButtonStyle())
                .disabled(!canSubmit)
                .accessibilityIdentifier("register.submit")

                Text("Next you'll accept the terms and confirm you're \(FWBConfig.minimumAge) or over.")
                    .font(Theme.Typography.micro)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(Theme.Spacing.xl)
        }
        .fwbDismissKeyboardOnTap()
        .background(Theme.Colors.background)
        .navigationTitle("Create account")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focus = .name }
    }

    private func submit() {
        guard canSubmit else { return }
        fwbDismissKeyboard()
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await AuthService.shared.register(
                    displayName: displayName.trimmed,
                    email: email.trimmed,
                    password: password)
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}

// MARK: - Forgot password

struct ForgotPasswordView: View {
    @State private var email = ""
    @State private var isWorking = false
    @State private var didSend = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                SectionHeader(
                    title: "Reset password",
                    subtitle: "We'll email you a link to set a new one.")
                    .padding(.bottom, Theme.Spacing.sm)

                if didSend {
                    FWBCard {
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            Label("Check your email", systemImage: "envelope.badge")
                                .font(Theme.Typography.rowTitle)
                            // Never confirms whether the address is registered —
                            // that would be an account-existence oracle, and the
                            // server is careful about it too.
                            Text("If there's an account for that address, a reset link is on its way.")
                                .font(Theme.Typography.preview)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    FWBTextField(title: "Email", text: $email,
                                 systemImage: "envelope",
                                 contentType: .emailAddress,
                                 keyboard: .emailAddress,
                                 submitLabel: .send) { submit() }
                        .focused($focused)

                    FormErrorText(message: errorMessage)

                    Button {
                        submit()
                    } label: {
                        if isWorking { ProgressView().tint(Theme.Colors.onBrand) } else { Text("Send reset link") }
                    }
                    .buttonStyle(FWBPrimaryButtonStyle())
                    .disabled(email.trimmed.isEmpty || isWorking)
                }
            }
            .padding(Theme.Spacing.xl)
        }
        .fwbDismissKeyboardOnTap()
        .background(Theme.Colors.background)
        .navigationTitle("Reset password")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = true }
    }

    private func submit() {
        guard !email.trimmed.isEmpty, !isWorking else { return }
        fwbDismissKeyboard()
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await AuthService.shared.forgotPassword(email: email.trimmed)
                didSend = true
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}

// MARK: - Helpers

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

#Preview {
    AuthFlowView()
}
