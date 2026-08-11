import SwiftUI

/// Settings — a trailing-separated tab (`RootTabView`), not a Profile sub-screen
/// (house convention, `feedback_settings_separated_tab_role_search`). Scaffold
/// scope: appearance + icon picker only, per PLAN.md §5's "ported kit, no
/// feature screens yet" directive. Notification prefs, account management, and
/// the rest of Profile's settings surface (PLAN.md §5.3/§5.4) land with those
/// features.
struct SettingsView: View {
    @State private var appearance = AppearanceService.shared
    @State private var auth = AuthService.shared
    @State private var onboarding = OnboardingService.shared

    var body: some View {
        Form {
            appearanceSection
            accountSection
            aboutSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Appearance

    @ViewBuilder
    private var appearanceSection: some View {
        @Bindable var appearance = appearance
        Section("Appearance") {
            Picker("Theme", selection: $appearance.theme) {
                ForEach(AppearanceService.Theme.allCases) { Text($0.label).tag($0) }
            }
        }
        Section("App Icon") {
            AppIconPicker()
        }
    }

    // MARK: - Account
    //
    // Account *management* (edit, sign out, delete) lives on the Profile tab —
    // this is a read-only pointer so both surfaces don't own the same actions.

    private var accountSection: some View {
        Section("Account") {
            if let user = auth.user {
                LabeledContent("Name", value: user.displayName)
                LabeledContent("Email", value: user.email)
                LabeledContent("Membership", value: user.vettingLabel)
            } else {
                Text("Not signed in").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: appVersion)
            Link(destination: URL(string: "mailto:\(FWBConfig.supportEmail)")!) {
                LabeledContent("Support", value: FWBConfig.supportEmail)
            }
            Link("Terms of use", destination: FWBConfig.termsURL)
            Link("Privacy policy", destination: FWBConfig.privacyURL)
            Link("Community guidelines", destination: FWBConfig.guidelinesURL)

            if onboarding.isRunningOnLocalRecordOnly && auth.isSignedIn {
                // Deliberately visible rather than swallowed. "The server has no
                // record of your terms acceptance" is exactly the kind of thing
                // that should not be a silent local-only state.
                Label("Your terms acceptance is stored on this device and hasn't reached the server yet.",
                      systemImage: "exclamationmark.icloud")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.caution)
            }
        } header: {
            Text("About")
        } footer: {
            Text("fwb social")
        }
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }
}

#Preview {
    NavigationStack { SettingsView() }
}
