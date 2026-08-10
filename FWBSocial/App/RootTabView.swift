import SwiftUI

/// The app's tab shell (PLAN.md §5.3). Settings is a trailing-separated tab via
/// `Tab(role: .search)` — the house convention (`feedback_settings_separated_tab_role_search`
/// memory; reference implementation: Sentinel's `RootView.swift` `StatusboardRootView`,
/// ~lines 195-260). `SettingsView` is not `.searchable` — the role is borrowed
/// only for its placement, not any search affordance.
struct RootTabView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        TabView(selection: $appState.selectedTab) {
            Tab(FWBTab.home.title, systemImage: FWBTab.home.systemImage, value: FWBTab.home) {
                NavigationStack { HomeView() }
            }

            Tab(FWBTab.channels.title, systemImage: FWBTab.channels.systemImage, value: FWBTab.channels) {
                NavigationStack { ChannelsView() }
            }

            Tab(FWBTab.events.title, systemImage: FWBTab.events.systemImage, value: FWBTab.events) {
                NavigationStack { EventsView() }
            }

            Tab(FWBTab.chat.title, systemImage: FWBTab.chat.systemImage, value: FWBTab.chat) {
                NavigationStack { ChatListView() }
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
    }
}
