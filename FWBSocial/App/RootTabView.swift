import SwiftUI

/// The app's tab shell.
///
/// **OWNER NAVIGATION DIRECTIVE 2026-08-10: four tabs.** Home / Channels / Chat /
/// Events. Profile and Settings left the bar for the top-left avatar and top-right
/// gear that `rootSurfaceChrome()` puts on every root surface — which is also what
/// made room for Events, since iPhone's bar holds five and a sixth was collapsing
/// Profile (sign-out, account deletion) into the "More" overflow.
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
                NavigationStack(path: $appState.announcementPath) { HomeView().fwbAppThemeSurface() }
            }

            // Gated on `FWBFeatures` — see AppState.swift. At Phase 3 these
            // have no feature behind them, and carrying three empty tabs pushed
            // Profile (sign-out, account deletion) into the "More" overflow.
            if FWBTab.channels.isEnabled {
                Tab(FWBTab.channels.title, systemImage: FWBTab.channels.systemImage, value: FWBTab.channels) {
                    NavigationStack { memberOnly(ChannelsView(), tab: .channels).fwbAppThemeSurface() }
                }
            }

            if FWBTab.chat.isEnabled {
                // message.fill ↔ message.badge.fill: the badged glyph itself
                // signals unread (owner directive), alongside the count badge.
                Tab(FWBTab.chat.title,
                    systemImage: chat.unreadTotal > 0 ? "message.badge.fill" : FWBTab.chat.systemImage,
                    value: FWBTab.chat) {
                    // The path lives in AppState so a chat push — or a thread
                    // started from inside the new-conversation sheet — can push a
                    // thread onto a tab that was never opened.
                    NavigationStack(path: $appState.chatPath) {
                        memberOnly(ChatListView(), tab: .chat)
                            .fwbAppThemeSurface()
                            .navigationDestination(for: UUID.self) { conversationId in
                                ChatThreadView(conversationId: conversationId)
                                    .fwbAppThemeSurface()
                            }
                    }
                }
                .badge(chat.unreadTotal)
            }

            if FWBTab.events.isEnabled {
                Tab(FWBTab.events.title, systemImage: FWBTab.events.systemImage, value: FWBTab.events) {
                    // Path in AppState so a FRIENDING_WINDOW push can deep-link the
                    // roster on a tab that was never opened.
                    NavigationStack(path: $appState.eventPath) {
                        memberOnly(EventsView(), tab: .events)
                            .fwbAppThemeSurface()
                    }
                }
            }

            // The fifth slot (owner directives 2026-08-11): four tabs grouped
            // left, one contextual action on the right. The slot is ALWAYS
            // present so the four main tabs keep identical spacing on every
            // page — when the surface has no action, the slot renders an empty
            // glyph and selecting it does nothing (see the intercept below).
            // `role: .search` gives it the system's separated trailing
            // treatment; it never presents content of its own.
            Tab(value: FWBTab.compose, role: .search) {
                Color.clear // never shown — selection is intercepted
            } label: {
                if let contextual = appState.contextualAction {
                    Label(contextual.label, systemImage: contextual.systemImage)
                } else {
                    // An empty UIImage holds the slot without drawing a glyph.
                    Label { Text("") } icon: { Image(uiImage: UIImage()) }
                }
            }

        }
        .tint(Theme.Colors.brand)
        // The compose slot is an action, not a destination: fire the registered
        // handler (if any — the slot is a space-holding no-op otherwise) and
        // snap the selection back before the empty content can render.
        .onChange(of: appState.selectedTab) { previous, current in
            if current == .compose {
                appState.selectedTab = previous
                appState.contextualAction?.handler()
            }
        }
        .sheet(isPresented: $appState.isPresentingAuth) { AuthFlowView() }
        .sheet(isPresented: $appState.isPresentingDevices) {
            NavigationStack { DeviceManagementView() }
        }
        // A `REPORT_FILED` push lands here. Presented from the tab shell rather
        // than from Settings so the deep link works from whichever tab was last
        // open, and so it survives the Settings sheet not being up.
        .sheet(isPresented: $appState.isPresentingReportQueue) {
            NavigationStack { ReportQueueView() }
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
