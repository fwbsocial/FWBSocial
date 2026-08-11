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
    @State private var chat = ChatService.shared

    var body: some View {
        @Bindable var appState = appState

        TabView(selection: $appState.selectedTab) {
            Tab(FWBTab.home.title, systemImage: FWBTab.home.systemImage, value: FWBTab.home) {
                // Path lives in AppState so an announcement push can navigate a
                // tab the member hasn't opened yet.
                NavigationStack(path: $appState.announcementPath) { HomeView() }
            }

            // Gated on `FWBFeatures` — see AppState.swift. At Phase 3 these
            // have no feature behind them, and carrying three empty tabs pushed
            // Profile (sign-out, account deletion) into the "More" overflow.
            if FWBTab.channels.isEnabled {
                Tab(FWBTab.channels.title, systemImage: FWBTab.channels.systemImage, value: FWBTab.channels) {
                    NavigationStack { memberOnly(ChannelsView(), tab: .channels) }
                }
            }

            if FWBTab.events.isEnabled {
                Tab(FWBTab.events.title, systemImage: FWBTab.events.systemImage, value: FWBTab.events) {
                    // Path in AppState so a FRIENDING_WINDOW push can deep-link the
                    // roster on a tab that was never opened.
                    NavigationStack(path: $appState.eventPath) {
                        memberOnly(EventsView(), tab: .events)
                    }
                }
            }

            if FWBTab.chat.isEnabled {
                Tab(FWBTab.chat.title, systemImage: FWBTab.chat.systemImage, value: FWBTab.chat) {
                    // The path lives in AppState so a chat push — or a thread
                    // started from inside the new-conversation sheet — can push a
                    // thread onto a tab that was never opened.
                    NavigationStack(path: $appState.chatPath) {
                        memberOnly(ChatListView(), tab: .chat)
                            .navigationDestination(for: UUID.self) { conversationId in
                                ChatThreadView(conversationId: conversationId)
                            }
                    }
                }
                .badge(chat.unreadTotal)
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
        .sheet(isPresented: $appState.isPresentingDevices) {
            NavigationStack { DeviceManagementView() }
        }
        // A conversation queued from a push, or from the new-conversation sheet
        // (which cannot push onto the list's own stack from inside itself).
        // Consumed and cleared, so a second drain can't re-navigate.
        .onChange(of: appState.pendingConversationId) { _, id in
            guard let id else { return }
            appState.pendingConversationId = nil
            appState.selectedTab = .chat
            if appState.chatPath.last != id { appState.chatPath.append(id) }
        }
        .onChange(of: auth.isSignedIn) { _, signedIn in
            if signedIn {
                Task { await chat.start() }
            } else {
                chat.handleSignOut()
            }
        }
        .task {
            // Session restore already ran in `FWBSocialApp`; if it produced a
            // session, enrol this device now rather than waiting for the member to
            // open the Chat tab. `PUT /api/chat/devices` sits outside the vetting
            // gate precisely so this can happen at first login (§4.6).
            if auth.isSignedIn { await chat.start() }
        }
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
