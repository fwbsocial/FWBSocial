import SwiftUI

// MARK: - Profile
//
// PLAN.md §5.3's Profile tab, at Phase 3 scope: identity, vetting status,
// notification preferences, support, sign out, delete account. Friends, blocked
// users, devices + safety numbers and inbox privacy land with the features that
// give them meaning (Phases 5–7).
//
// App-level settings (appearance, icon picker) live on the separated Settings
// tab, not here — house convention.

struct ProfileView: View {
    @Environment(ToastCenter.self) private var toasts
    @Environment(AppState.self) private var appState
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var auth = AuthService.shared
    @State private var showEditProfile = false
    @State private var showDeleteConfirm = false
    @State private var showSignOutConfirm = false
    @State private var isDeleting = false
    @State private var errorMessage: String?

    @State private var lumaStatus: LumaEmailStatusDTO?

    /// Deliberately swallowed. This only decides whether the Luma row says
    /// "Linked" or "Not linked", and the row is informational — an error banner on
    /// the profile screen because a secondary status call timed out would be more
    /// alarming than the thing it reports. The row reads "Not linked" either way,
    /// which is the safe direction to be wrong in: it invites the member to link,
    /// and linking is idempotent.
    private func loadLumaStatus() async {
        lumaStatus = try? await EventsAPI.lumaEmailStatus()
    }

    var body: some View {
        Group {
            if let user = auth.user {
                signedIn(user)
            } else {
                EmptyStateView(
                    icon: "person.crop.circle",
                    title: "Not signed in",
                    message: "Sign in to see your profile, membership status and notification settings.",
                    actionTitle: "Sign in",
                    action: { appState.isPresentingAuth = true })
            }
        }
        .navigationTitle("Profile")
        .sheet(isPresented: $showEditProfile) { EditProfileView() }
        .task {
            await auth.reloadUser()
            await loadLumaStatus()
        }
    }

    // MARK: Signed in

    @ViewBuilder
    private func signedIn(_ user: AuthUser) -> some View {
        List {
            Group {
                Section {
                    HStack(spacing: Theme.Spacing.md) {
                        AvatarView(name: user.displayName, url: user.avatarUrl, size: 60)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(user.displayName)
                                .font(Theme.Typography.title)
                            Text(user.email)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(.secondary)
                            if let username = user.username {
                                Text("@\(username)")
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, Theme.Spacing.xs)

                    Button("Edit profile") { showEditProfile = true }
                        .accessibilityIdentifier("profile.editProfile")
                }

                Section {
                    LabeledContent("Status") {
                        StatusBadge(user.vettingLabel,
                                    color: user.isVetted ? Theme.Colors.positive : Theme.Colors.caution)
                    }
                    if !user.isVetted {
                        Text("Access opens up once we've matched you to an event check-in.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)
                    }

                    // The Luma-email link (§4.5.3). It lives in Membership rather than
                    // in a settings list because it is the mechanism by which a pending
                    // member becomes vetted — for a Sign in with Apple member using the
                    // private relay, it is the ONLY one. Shown even once verified, so
                    // there is somewhere to change it.
                    NavigationLink {
                        LumaEmailLinkView(status: lumaStatus) { await loadLumaStatus() }
                    } label: {
                        LabeledContent("Luma email") {
                            if let lumaStatus, lumaStatus.verified, let address = lumaStatus.lumaEmail {
                                // Middle truncation on one line keeps the domain
                                // visible, which is the point — but at accessibility
                                // sizes one line of a `LabeledContent` value column is
                                // a couple of characters, so the address becomes
                                // unreadable exactly when readability is the request.
                                // Two lines at the largest sizes, one otherwise.
                                Text(address)
                                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                                    .truncationMode(.middle)
                            } else if lumaStatus?.promptRequired == true {
                                StatusBadge("Needed", color: Theme.Colors.caution)
                            } else {
                                Text("Not linked").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("profile.lumaEmail")
                    if user.isAdmin {
                        LabeledContent("Role", value: "Admin")
                    } else if user.isModerator {
                        LabeledContent("Role", value: "Moderator")
                    }
                    if let code = user.friendCode {
                        // Friend codes are the out-of-band invite path (member
                        // search is deliberately absent — commissioner decision 9),
                        // so copying/sharing must be one tap.
                        HStack {
                            LabeledContent("Friend code") {
                                Text(code)
                                    .font(.body.monospaced())
                                    .textSelection(.enabled)
                            }
                            ShareLink(item: "Add me on fwb social — friend code: \(code)") {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .buttonStyle(.borderless)
                            // Supplying a custom image-only label suppresses ShareLink's
                            // own "Share" label, leaving VoiceOver with a bare button.
                            .accessibilityLabel("Share your friend code")
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            UIPasteboard.general.string = code
                            toasts.show("Friend code copied")
                        }
                    }
                } header: {
                    Text("Membership")
                        .fwbOnCanvas()
                }

                if !user.emailVerified {
                    Section {
                        // Email verification is dormant server-side for now, so this
                        // is informational rather than a blocker — nothing in the app
                        // is gated on it yet.
                        Label("Email not verified", systemImage: "envelope.badge")
                            .foregroundStyle(Theme.Colors.caution)
                        Button("Resend verification email") { resendVerification() }
                    }
                }

                NotificationPreferencesSection()

                Section {
                    Link(destination: URL(string: "mailto:\(FWBConfig.supportEmail)")!) {
                        LabeledContent("Contact us", value: FWBConfig.supportEmail)
                    }
                    Link("Community guidelines", destination: FWBConfig.guidelinesURL)
                    Link("Terms of use", destination: FWBConfig.termsURL)
                    Link("Privacy policy", destination: FWBConfig.privacyURL)
                } header: {
                    Text("Support")
                        .fwbOnCanvas()
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(Theme.Colors.danger) }
                }

                Section {
                    Button("Sign out") { showSignOutConfirm = true }
                        .accessibilityIdentifier("profile.signOut")
                }

                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        if isDeleting {
                            HStack { ProgressView(); Text("Deleting…") }
                        } else {
                            Text("Delete account")
                        }
                    }
                    .disabled(isDeleting)
                    .accessibilityIdentifier("profile.deleteAccount")
                } footer: {
                    // Guideline 5.1.1(v). Say what actually happens — the server
                    // scrambles the identifying columns, revokes the Apple grant and
                    // drops every token; forum posts are tombstoned to "Deleted
                    // member" rather than erased.
                    Text("Deleting removes your account, revokes any Sign in with Apple grant and signs you out everywhere. Posts you've made stay, attributed to a deleted member. This can't be undone.")
                    .fwbOnCanvas()
                }
            }
            // Row backgrounds are a per-row trait — see `fwbThemedRows()`.
            // The Group is the one place inside the List that every section
            // can inherit it from.
            .fwbThemedRows()
        }
        .confirmationDialog("Sign out?", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { auth.signOut() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete your account?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete account", role: .destructive) { deleteAccount() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your fwb social account. It can't be undone.")
        }
    }

    private func resendVerification() {
        Task {
            do {
                try await auth.resendVerification()
                toasts.success("Verification email sent")
            } catch {
                toasts.error(error.fwbMessage)
            }
        }
    }

    private func deleteAccount() {
        isDeleting = true
        errorMessage = nil
        Task {
            do {
                try await auth.deleteAccount()
                toasts.success("Account deleted")
            } catch {
                errorMessage = error.fwbMessage
            }
            isDeleting = false
        }
    }
}

// MARK: - Notification preferences

/// Announcement pushes are opt-OUT (commissioner Q4): everyone gets them by
/// default and can turn them off here.
///
/// Reads and writes `GET|PUT /api/me/notifications` — a dedicated route rather
/// than a corner of the profile update, which is what the server offers. State
/// is loaded from that route rather than from the cached `/me` user, so a toggle
/// reflects what the server actually holds and not a stale copy.
struct NotificationPreferencesSection: View {
    @Environment(ToastCenter.self) private var toasts

    @State private var prefs: NotificationPreferences?
    @State private var isSaving = false
    // A `Bool` here meant the caught error was discarded at the `catch`, so the
    // server's explanation never reached the screen. Keep the error itself.
    @State private var loadError: Error?

    var body: some View {
        Section {
            if let prefs {
                toggle("Announcements", value: prefs.notifyAnnouncements) {
                    NotificationPreferencesUpdate(notifyAnnouncements: $0)
                }
                toggle("Direct messages", value: prefs.notifyDm) {
                    NotificationPreferencesUpdate(notifyDm: $0)
                }
                toggle("Friend requests", value: prefs.notifyFriendRequests) {
                    NotificationPreferencesUpdate(notifyFriendRequests: $0)
                }
                toggle("Channel posts", value: prefs.notifyChannelPosts) {
                    NotificationPreferencesUpdate(notifyChannelPosts: $0)
                }
            } else if let loadError {
                // Was a flat "Couldn't load your notification settings." with no
                // retry, which left the member staring at a dead section: the
                // toggles below are `.disabled(prefs == nil)`, so a failed load
                // silently greys out the whole of notification control.
                InlineErrorRow(message: loadError.fwbMessage) { Task { await load(force: true) } }
            } else {
                ProgressView()
            }
        } header: {
            Text("Notifications")
            .fwbOnCanvas()
        } footer: {
            Text("You'll only get notifications for features you have access to.")
            .fwbOnCanvas()
        }
        .disabled(isSaving)
        .task { await load(force: false) }
    }

    private func toggle(
        _ title: String,
        value: Bool,
        update: @escaping (Bool) -> NotificationPreferencesUpdate
    ) -> some View {
        Toggle(title, isOn: Binding(
            get: { value },
            set: { newValue in save(update(newValue)) }
        ))
        .tint(Theme.Colors.brand)
    }

    private func load(force: Bool) async {
        guard prefs == nil else { return }
        // Without `force`, a retry after a failure was a no-op: the `.task` guard
        // only checks `prefs == nil`, which is still true, so nothing re-fetched.
        if loadError != nil && !force { return }
        loadError = nil
        do {
            prefs = try await APIClient.shared.notificationPreferences()
        } catch {
            guard !isCancellationError(error) else { return }
            loadError = error
        }
    }

    private func save(_ update: NotificationPreferencesUpdate) {
        isSaving = true
        Task {
            do {
                // The response is the server's new state, so the toggles settle
                // on what actually landed rather than on what was asked for.
                prefs = try await APIClient.shared.updateNotificationPreferences(update)
            } catch {
                toasts.error(error.fwbMessage)
                // Re-read the server's actual state so a failed write doesn't
                // leave the toggle showing what was asked for.
                prefs = nil
                await load(force: true)
            }
            isSaving = false
        }
    }
}

// `EditProfileView` — photo, display name, username, bio — lives in its own
// file (`EditProfileView.swift`).

#Preview {
    NavigationStack { ProfileView() }
        .environment(ToastCenter())
        .environment(AppState.shared)
}
