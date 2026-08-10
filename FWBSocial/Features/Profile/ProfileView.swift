import SwiftUI

/// Placeholder for the Profile tab (PLAN.md §5.3): me, friends, inbox privacy,
/// discoverability, devices + safety numbers, support, delete account. Admin
/// section appears when privileged. App-level settings (appearance, icon) live
/// on the separated Settings tab, not here — see `SettingsView`.
struct ProfileView: View {
    @State private var auth = AuthService.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                SectionHeader(title: "Profile", subtitle: "You, friends, and privacy.", eyebrow: "Account")
                if let user = auth.user {
                    FWBCard {
                        HStack(spacing: Theme.Spacing.md) {
                            AvatarView(name: user.displayName, url: user.avatarUrl, size: 48)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.displayName).font(Theme.Typography.rowTitle)
                                Text(user.email).font(Theme.Typography.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            StatusBadge(user.isVetted ? "Vetted" : "Pending", color: user.isVetted ? Theme.Colors.positive : Theme.Colors.caution)
                        }
                    }
                } else {
                    EmptyStateView(
                        icon: "person.crop.circle",
                        title: "Not signed in",
                        message: "Sign in to see your profile, friends, and privacy settings.")
                }
            }
            .padding()
        }
        .navigationTitle("Profile")
    }
}

#Preview {
    NavigationStack { ProfileView() }
}
