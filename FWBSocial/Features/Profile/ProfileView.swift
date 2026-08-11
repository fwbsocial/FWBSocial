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

    @State private var auth = AuthService.shared
    @State private var showEditProfile = false
    @State private var showDeleteConfirm = false
    @State private var showSignOutConfirm = false
    @State private var isDeleting = false
    @State private var errorMessage: String?

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
        .task { await auth.reloadUser() }
    }

    // MARK: Signed in

    @ViewBuilder
    private func signedIn(_ user: AuthUser) -> some View {
        List {
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
            }

            Section("Membership") {
                LabeledContent("Status") {
                    StatusBadge(user.vettingLabel,
                                color: user.isVetted ? Theme.Colors.positive : Theme.Colors.caution)
                }
                if !user.isVetted {
                    Text("Access opens up once we've matched you to an event check-in.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                if user.isAdmin {
                    LabeledContent("Role", value: "Admin")
                } else if user.isModerator {
                    LabeledContent("Role", value: "Moderator")
                }
                if let code = user.friendCode {
                    LabeledContent("Friend code", value: code)
                }
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

            NotificationPreferencesSection(user: user)

            Section("Avatar") {
                // R2 is not provisioned yet (PLAN.md Phase 0), so the upload
                // endpoint has nowhere to put the bytes. The control is left out
                // rather than shipped broken.
                Label {
                    Text("Photo uploads aren't switched on yet.")
                } icon: {
                    Image(systemName: "photo.badge.plus")
                }
                .font(Theme.Typography.preview)
                .foregroundStyle(.secondary)
            }

            Section("Support") {
                Link(destination: URL(string: "mailto:\(FWBConfig.supportEmail)")!) {
                    LabeledContent("Contact us", value: FWBConfig.supportEmail)
                }
                Link("Community guidelines", destination: FWBConfig.guidelinesURL)
                Link("Terms of use", destination: FWBConfig.termsURL)
                Link("Privacy policy", destination: FWBConfig.privacyURL)
            }

            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(Theme.Colors.danger) }
            }

            Section {
                Button("Sign out") { showSignOutConfirm = true }
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
            } footer: {
                // Guideline 5.1.1(v). Say what actually happens — the server
                // scrambles the identifying columns, revokes the Apple grant and
                // drops every token; forum posts are tombstoned to "Deleted
                // member" rather than erased.
                Text("Deleting removes your account, revokes any Sign in with Apple grant and signs you out everywhere. Posts you've made stay, attributed to a deleted member. This can't be undone.")
            }
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
                toasts.error(error.localizedDescription)
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
                errorMessage = error.localizedDescription
            }
            isDeleting = false
        }
    }
}

// MARK: - Notification preferences

/// Announcement pushes are opt-OUT (commissioner Q4): everyone vetted gets them
/// by default and can turn them off here. The other toggles are wired now
/// because the profile route already accepts them, even though the features
/// they gate land later — a preference that silently does nothing is better
/// than one that silently resets.
struct NotificationPreferencesSection: View {
    let user: AuthUser

    @Environment(ToastCenter.self) private var toasts
    @State private var isSaving = false

    var body: some View {
        Section {
            toggle("Announcements", value: user.notifyAnnouncements ?? true) {
                AuthService.ProfileUpdate(notifyAnnouncements: $0)
            }
            toggle("Direct messages", value: user.notifyDm ?? true) {
                AuthService.ProfileUpdate(notifyDm: $0)
            }
            toggle("Friend requests", value: user.notifyFriendRequests ?? true) {
                AuthService.ProfileUpdate(notifyFriendRequests: $0)
            }
            toggle("Channel posts", value: user.notifyChannelPosts ?? true) {
                AuthService.ProfileUpdate(notifyChannelPosts: $0)
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("You'll only get notifications for features you have access to.")
        }
        .disabled(isSaving)
    }

    private func toggle(
        _ title: String,
        value: Bool,
        update: @escaping (Bool) -> AuthService.ProfileUpdate
    ) -> some View {
        Toggle(title, isOn: Binding(
            get: { value },
            set: { newValue in save(update(newValue)) }
        ))
        .tint(Theme.Colors.brand)
    }

    private func save(_ update: AuthService.ProfileUpdate) {
        isSaving = true
        Task {
            do {
                try await AuthService.shared.updateProfile(update)
            } catch {
                toasts.error(error.localizedDescription)
            }
            isSaving = false
        }
    }
}

// MARK: - Edit profile

struct EditProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts

    @State private var displayName = ""
    @State private var bio = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var canSave: Bool {
        !displayName.trimmed.isEmpty && displayName.trimmed.count <= 50 && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Display name") {
                    TextField("Your name", text: $displayName)
                        .textInputAutocapitalization(.words)
                }
                Section("Bio") {
                    TextField("A line about you", text: $bio, axis: .vertical)
                        .lineLimit(3...6)
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(Theme.Colors.danger) }
                }
            }
            .navigationTitle("Edit profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!canSave)
                }
            }
            .onAppear {
                displayName = AuthService.shared.user?.displayName ?? ""
                bio = AuthService.shared.user?.bio ?? ""
            }
        }
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await AuthService.shared.updateProfile(
                    AuthService.ProfileUpdate(displayName: displayName.trimmed,
                                              bio: bio.trimmed.isEmpty ? nil : bio.trimmed))
                toasts.success("Profile updated")
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}

#Preview {
    NavigationStack { ProfileView() }
        .environment(ToastCenter())
        .environment(AppState.shared)
}
