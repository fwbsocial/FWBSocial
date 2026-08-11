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
    /// Why the preference toggles are inert. Kept as an `Error` rather than a
    /// flattened string so the offline branch of `fwbMessage` still applies.
    @State private var prefsError: Error?

    var body: some View {
        Form {
            Group {
                appearanceSection
                if auth.isSignedIn {
                    privacySection
                    chatSection
                    notificationsSection
                    safetySection
                }
                if auth.user?.isAdmin == true || auth.user?.isModerator == true {
                    moderationSection
                }
                accountSection
                aboutSection
            }
            // A row's background is a per-row trait: set on the Form from
            // OUTSIDE, it never reaches the rows, which is why the themed
            // Settings sheet had system-grey rows floating on pine. Set on a
            // Group INSIDE the form, every section inherits it.
            .fwbThemedRows()
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
            .fwbOnCanvas()
        } footer: {
            // Say what it actually controls. With no member search in v1, this is
            // the only inbound-contact path from the forum.
            Text("When this is off, members who find you through your posts and comments won't see a way to send you a friend request. There is no member search in fwb social — this is the only way someone can reach you from the forum.")
            .fwbOnCanvas()
        }
    }

    // MARK: - Chat
    //
    // Inbox privacy is §4.4's setting. E2EE does not touch it: conversation
    // membership, block rows and `inbox_policy` are metadata the server owns, and
    // it enforces them at conversation-create and add-member.
    //
    // `hideMessagePreviews` is the odd one out on this screen: it is the ONLY
    // setting whose enforcement is entirely client-side, because the server has
    // ciphertext and nothing to redact (§4.3.5). Saving it does two things —
    // persists the column AND mirrors it into the App Group, without which the
    // column is inert and the toggle silently does nothing.

    @ViewBuilder
    private var chatSection: some View {
        Section {
            Picker("Who can message you", selection: Binding(
                get: { InboxPolicy(rawValue: auth.user?.inboxPolicy ?? "") ?? .friendsOnly },
                set: { newValue in Task { await saveInboxPolicy(newValue) } }
            )) {
                ForEach(InboxPolicy.allCases) { policy in
                    Text(policy.label).tag(policy)
                }
            }
            .accessibilityIdentifier("settings.inboxPolicy")

            Toggle("Hide message previews", isOn: Binding(
                get: { auth.user?.hideMessagePreviews ?? false },
                set: { newValue in Task { await saveHidePreviews(newValue) } }
            ))
            .accessibilityIdentifier("settings.hidePreviews")

            NavigationLink {
                DeviceManagementView()
            } label: {
                Label("Devices", systemImage: "iphone.gen3")
            }

            NavigationLink {
                FriendsView()
            } label: {
                Label("Friends", systemImage: "person.2")
            }
        } header: {
            Text("Chat")
            .fwbOnCanvas()
        } footer: {
            Text(
                (InboxPolicy(rawValue: auth.user?.inboxPolicy ?? "") ?? .friendsOnly).explanation
                    + "\n\nWith previews hidden, notifications say “New message” and nothing else — the decryption that produces a preview happens on this device, so turning it off really does stop it happening."
            )
            .fwbOnCanvas()
        }
    }

    // MARK: - Notifications

    @ViewBuilder
    private var notificationsSection: some View {
        Section {
            // The load failing used to be invisible: every toggle below simply went
            // dead, showing its default value, with nothing to say why and no way to
            // ask again. Now the reason is the server's own sentence and the retry is
            // one tap. The row sits OUTSIDE the disabled group deliberately — a
            // "Try again" button inside it would be disabled by the very failure it
            // exists to recover from.
            if let prefsError {
                InlineErrorRow(message: prefsError.fwbMessage) { Task { await loadPrefs() } }
            }

            Group {
                Toggle("Announcements", isOn: Binding(
                    get: { prefs?.notifyAnnouncements ?? true },
                    set: { savePrefs { $0.notifyAnnouncements = $1 }($0) }))
                Toggle("Messages", isOn: Binding(
                    get: { prefs?.notifyDm ?? true },
                    set: { savePrefs { $0.notifyDm = $1 }($0) }))
                Toggle("Friend requests", isOn: Binding(
                    get: { prefs?.notifyFriendRequests ?? true },
                    set: { savePrefs { $0.notifyFriendRequests = $1 }($0) }))
                Toggle("New posts in channels", isOn: Binding(
                    get: { prefs?.notifyChannelPosts ?? true },
                    set: { savePrefs { $0.notifyChannelPosts = $1 }($0) }))
            }
            .disabled(prefs == nil)
        } header: {
            Text("Notifications")
            .fwbOnCanvas()
        } footer: {
            Text("Channel notifications are throttled and grouped, and you can mute any single channel or conversation from its own screen.")
            .fwbOnCanvas()
        }
    }

    // MARK: - Chat preference plumbing

    private func saveInboxPolicy(_ policy: InboxPolicy) async {
        do {
            try await auth.updateProfile(inboxPolicy: policy.rawValue)
        } catch {
            // The server's own sentence, not ours. "Couldn't save that setting."
            // replaced messages that actually distinguish a rejected value from a
            // dropped connection, and left the member with nothing to act on.
            toasts.error(error.fwbMessage)
        }
    }

    private func saveHidePreviews(_ hide: Bool) async {
        // Mirror FIRST so the extension is right even if the network write is slow;
        // the column and the mirror are reconciled on the next session restore.
        AppGroupStore.hideMessagePreviews = hide
        do {
            try await auth.updateProfile(hideMessagePreviews: hide)
        } catch {
            AppGroupStore.hideMessagePreviews = !hide
            toasts.error(error.fwbMessage)
        }
    }

    // MARK: - Safety

    private var safetySection: some View {
        Section {
            NavigationLink {
                BlockedMembersView()
            } label: {
                Label("Blocked members", systemImage: "hand.raised")
            }
        } header: {
            Text("Safety")
                .fwbOnCanvas()
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
            .fwbOnCanvas()
        } footer: {
            Text("Reports should be actioned within 24 hours.")
            .fwbOnCanvas()
        }
    }

    // MARK: - Preferences plumbing

    private func loadPrefs() async {
        guard auth.isSignedIn, prefs == nil, !isLoadingPrefs else { return }
        isLoadingPrefs = true
        prefsError = nil
        do {
            prefs = try await APIClient.shared.notificationPreferences()
        } catch {
            // Cancellation is the member leaving the tab, not a failure to explain.
            if !isCancellationError(error) { prefsError = error }
        }
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
                    toasts.error(error.fwbMessage)
                }
            }
        }
    }

    // MARK: - Appearance

    @ViewBuilder
    private var appearanceSection: some View {
        @Bindable var appearance = appearance
        Section {
            Picker("Theme", selection: $appearance.theme) {
                ForEach(AppearanceService.Theme.allCases) { Text($0.label).tag($0) }
            }
            .accessibilityIdentifier("settings.appearanceTheme")
        } header: {
            Text("Appearance")
            .fwbOnCanvas()
        }

        Section {
            Picker("App theme", selection: $appearance.appTheme) {
                ForEach(AppTheme.allCases) { Text($0.label).tag($0) }
            }
            .accessibilityIdentifier("settings.appTheme")
        } header: {
            Text("App Theme")
            .fwbOnCanvas()
        } footer: {
            // The selected theme's own sentence — which, for Pine, is where the
            // member finds out the appearance picker above it does not apply.
            Text(appearance.appTheme.blurb)
            .fwbOnCanvas()
        }

        Section {
            AppIconPicker()
        } header: {
            Text("App Icon")
                .fwbOnCanvas()
        }
    }

    // MARK: - Account
    //
    // Account *management* (edit, sign out, delete) lives on the Profile tab —
    // this is a read-only pointer so both surfaces don't own the same actions.

    private var accountSection: some View {
        Section {
            if let user = auth.user {
                LabeledContent("Name", value: user.displayName)
                LabeledContent("Email", value: user.email)
                LabeledContent("Membership", value: user.vettingLabel)
            } else {
                Text("Not signed in").foregroundStyle(.secondary)
            }
        } header: {
            Text("Account")
                .fwbOnCanvas()
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
            .fwbOnCanvas()
        } footer: {
            Text("fwb social")
            .fwbOnCanvas()
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
