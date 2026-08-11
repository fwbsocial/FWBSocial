import SwiftUI

/// The app's tab shell (PLAN.md §5.3). Settings is a trailing-separated tab via
/// `Tab(role: .search)` — the house convention. `SettingsView` is not
/// `.searchable`; the role is borrowed only for its placement.
///
/// **The shell is not behind auth.** Home renders announcements signed out
/// (PLAN.md §4.1); the member-only tabs show a sign-in prompt instead of an
/// empty screen. The onboarding gate (terms + 18+) covers everything once a
/// session exists but hasn't cleared both gates — see `FWBSocialApp`.
struct RootTabView: View {
    @Environment(AppState.self) private var appState
    @State private var auth = AuthService.shared

    var body: some View {
        @Bindable var appState = appState

        TabView(selection: $appState.selectedTab) {
            Tab(FWBTab.home.title, systemImage: FWBTab.home.systemImage, value: FWBTab.home) {
                // Path lives in AppState so an announcement push can navigate a
                // tab the member hasn't opened yet.
                NavigationStack(path: $appState.announcementPath) { HomeView() }
            }

            Tab(FWBTab.channels.title, systemImage: FWBTab.channels.systemImage, value: FWBTab.channels) {
                NavigationStack { memberOnly(ChannelsView(), tab: .channels) }
            }

            Tab(FWBTab.events.title, systemImage: FWBTab.events.systemImage, value: FWBTab.events) {
                NavigationStack { memberOnly(EventsView(), tab: .events) }
            }

            Tab(FWBTab.chat.title, systemImage: FWBTab.chat.systemImage, value: FWBTab.chat) {
                NavigationStack { memberOnly(ChatListView(), tab: .chat) }
            }

            Tab(FWBTab.profile.title, systemImage: FWBTab.profile.systemImage, value: FWBTab.profile) {
                NavigationStack { ProfileView() }
            }

            // `role: .search` pins this tab trailing-separated in the stock bar
            // regardless of source order — the mechanism, not a search feature.
            Tab(FWBTab.settings.title, systemImage: FWBTab.settings.systemImage,
                value: FWBTab.settings, role: .search) {
                NavigationStack { SettingsView() }
            }
        }
        .tint(Theme.Colors.brand)
        .sheet(isPresented: $appState.isPresentingAuth) { AuthFlowView() }
    }

    /// Member-only tabs: the real screen when signed in, an honest prompt when
    /// not. Showing an empty feed to a signed-out visitor reads as a broken app.
    @ViewBuilder
    private func memberOnly<Content: View>(_ content: Content, tab: FWBTab) -> some View {
        if auth.isSignedIn {
            content
        } else {
            EmptyStateView(
                icon: "person.crop.circle.badge.questionmark",
                title: "Members only",
                message: "Sign in to use \(tab.title.lowercased()).",
                actionTitle: "Sign in",
                action: { AppState.shared.isPresentingAuth = true })
            .navigationTitle(tab.title)
        }
    }
}
