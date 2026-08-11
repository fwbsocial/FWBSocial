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

    @Environment(ToastCenter.self) private var toasts

    @State private var prefs: NotificationPreferences?
    @State private var isLoadingPrefs = false

    var body: some View {
        Form {
            appearanceSection
            if auth.isSignedIn {
                privacySection
                notificationsSection
                safetySection
            }
            if auth.user?.isAdmin == true || auth.user?.isModerator == true {
                moderationSection
            }
            accountSection
            aboutSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadPrefs() }
    }

    // MARK: - Privacy
    //
    // Commissioner decision 9's per-user switch. It rides on the notification
    // preferences endpoint rather than a route of its own — the server put it
    // there deliberately ("it lives on the same settings screen and shipping it
    // here means the iOS settings surface does not grow a new endpoint two
    // phases from now").

    @ViewBuilder
    private var privacySection: some View {
        Section {
            Toggle("Allow friend requests from the forum", isOn: Binding(
                get: { prefs?.allowForumFriendRequests ?? true },
                set: { savePrefs { $0.allowForumFriendRequests = $1 }($0) }))
                .disabled(prefs == nil)
        } header: {
            Text("Privacy")
        } footer: {
            // Say what it actually controls. With no member search in v1, this is
            // the only inbound-contact path from the forum.
            Text("When this is off, members who find you through your posts and comments won't see a way to send you a friend request. There is no member search in fwb social — this is the only way someone can reach you from the forum.")
        }
    }

    // MARK: - Notifications

    @ViewBuilder
    private var notificationsSection: some View {
        Section {
            Toggle("Announcements", isOn: Binding(
                get: { prefs?.notifyAnnouncements ?? true },
                set: { savePrefs { $0.notifyAnnouncements = $1 }($0) }))
            Toggle("New posts in channels", isOn: Binding(
                get: { prefs?.notifyChannelPosts ?? true },
                set: { savePrefs { $0.notifyChannelPosts = $1 }($0) }))
        } header: {
            Text("Notifications")
        } footer: {
            Text("Channel notifications are throttled and grouped, and you can mute any single channel from its own screen.")
        }
        .disabled(prefs == nil)
    }

    // MARK: - Safety

    private var safetySection: some View {
        Section("Safety") {
            NavigationLink {
                BlockedMembersView()
            } label: {
                Label("Blocked members", systemImage: "hand.raised")
            }
        }
    }

    // MARK: - Moderation

    private var moderationSection: some View {
        Section {
            NavigationLink {
                ReportQueueView()
            } label: {
                Label("Report queue", systemImage: "flag")
            }
        } header: {
            Text("Moderation")
        } footer: {
            Text("Reports should be actioned within 24 hours.")
        }
    }

    // MARK: - Preferences plumbing

    private func loadPrefs() async {
        guard auth.isSignedIn, prefs == nil, !isLoadingPrefs else { return }
        isLoadingPrefs = true
        prefs = try? await APIClient.shared.notificationPreferences()
        isLoadingPrefs = false
    }

    /// Applies a change optimistically and pushes it. On failure the previous
    /// value is restored — a toggle that silently springs back with no
    /// explanation is worse than one that never moved.
    private func savePrefs(
        _ mutate: @escaping (inout NotificationPreferences, Bool) -> Void
    ) -> (Bool) -> Void {
        { newValue in
            guard var current = prefs else { return }
            let previous = current
            mutate(&current, newValue)
            prefs = current

            Task {
                do {
                    let saved = try await APIClient.shared.updateNotificationPreferences(
                        NotificationPreferencesUpdate(
                            notifyAnnouncements: current.notifyAnnouncements,
                            notifyDm: current.notifyDm,
                            notifyFriendRequests: current.notifyFriendRequests,
                            notifyChannelPosts: current.notifyChannelPosts,
                            allowForumFriendRequests: current.allowForumFriendRequests))
                    prefs = saved
                } catch {
                    guard !isCancellationError(error) else { return }
                    prefs = previous
                    toasts.error("Couldn't save that setting.")
                }
            }
        }
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
