import SwiftUI

// MARK: - Announcements feed (Home tab)
//
// PLAN.md §4.1. Two things about this screen are load-bearing rather than
// cosmetic:
//
//  * **It works signed out.** `APIClient.announcementsFeed` picks the public
//    route when there's no session. A reviewer who opens the app sees a working
//    product in three seconds instead of a login wall (Guideline 2.1).
//  * **The admin affordances are drawn from `isAdmin`, never trusted from it.**
//    The compose/edit/delete routes are behind the server's `RequireAdmin`; the
//    client flag decides what to draw and nothing else.

struct AnnouncementsFeedView: View {
    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts

    @State private var auth = AuthService.shared
    @State private var loader = PaginatedLoader<Announcement>(per: 20)
    @State private var showComposer = false
    @State private var editing: Announcement?
    @State private var pendingDelete: Announcement?
    @State private var schedulingUnpin: Announcement?
    @State private var showAuthSheet = false
    @State private var showFriendCode = false

    /// Pinned announcements ride at the top. The server is expected to order
    /// this way too; doing it here as well means a paginated fetch can't shuffle
    /// a pinned item below a newer one just because it landed on page two.
    private var orderedItems: [Announcement] {
        loader.items.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.pinned != rhs.element.pinned { return lhs.element.pinned }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    var body: some View {
        @Bindable var appState = appState

        ScrollView {
            LazyVStack(spacing: Theme.Spacing.md) {
                if !auth.isSignedIn {
                    signedOutCard
                } else if let user = auth.user, !user.isVetted {
                    vettingStatusCard(user)
                }

                if loader.items.isEmpty {
                    if loader.isLoading {
                        ProgressView()
                            .controlSize(.large)
                            .padding(.top, Theme.Spacing.xxl)
                    } else if let error = loader.error {
                        EmptyStateView(
                            icon: "wifi.exclamationmark",
                            title: "Couldn't load announcements",
                            message: error,
                            actionTitle: "Try again",
                            action: { Task { await reload() } })
                    } else {
                        EmptyStateView(
                            icon: "megaphone",
                            title: "No announcements yet",
                            message: auth.isAdmin
                                ? "Write the first one — it'll appear here and notify members who've opted in."
                                : "When there's news, it'll show up here.",
                            actionTitle: auth.isAdmin ? "New announcement" : nil,
                            action: auth.isAdmin ? { showComposer = true } : nil)
                    }
                } else {
                    ForEach(orderedItems) { announcement in
                        NavigationLink(value: announcement.id) {
                            AnnouncementRow(announcement: announcement, isAdmin: auth.isAdmin)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { adminMenu(for: announcement) }
                        // The kebab is an OVERLAY on the link, never inside its
                        // label: a control nested in a NavigationLink's label has
                        // its taps eaten by the link, so the menu would simply
                        // navigate instead of opening.
                        .overlay(alignment: .topTrailing) {
                            if auth.isAdmin {
                                AnnouncementKebabMenu(
                                    announcement: announcement,
                                    handlers: handlers(for: announcement))
                                .padding(.trailing, Theme.Spacing.xs)
                                .padding(.top, Theme.Spacing.xs)
                            }
                        }
                        .task {
                            let includeDrafts = auth.isAdmin
                            await loader.loadMoreIfNeeded(current: announcement) { page, per in
                                try await APIClient.shared.announcementsFeed(
                                    page: page, per: per, includeDrafts: includeDrafts)
                            }
                        }
                    }

                    if loader.isLoading {
                        ProgressView().padding(.vertical, Theme.Spacing.lg)
                    }
                }
            }
            .padding(Theme.Spacing.lg)
        }
        .background(Theme.Colors.background)
        .accessibilityIdentifier("home.feed")
        .refreshable { await reload() }
        .navigationTitle("fwb social")
        .navigationDestination(for: String.self) { id in
            AnnouncementDetailView(announcementId: id, preloaded: loader.items.first { $0.id == id })
                // A pushed destination is a SIBLING of this screen in the stack,
                // not a child — the surface applied to the tab root never reaches
                // it, and without this the announcement opened on the system's
                // plain background with no theme on it at all.
                .fwbAppThemeSurface()
        }
        // The compose affordance moved to the floating action button (owner
        // navigation directive) — the trailing corner is the gear now.
        .rootSurfaceChrome()
        // Owner directive 2026-08-11: the slot is never empty on a page a member
        // can act on. Writing an announcement is an admin power, so a member's Feed
        // carries the one thing every member can do from the screen they open most
        // — hand out the code that is the only self-service way onto their friends
        // list (commissioner decision 9 removes member search entirely).
        //
        // Signed OUT is the honest exception: there is no code to share and no
        // account to share it from. The slot holds its space and draws nothing.
        .floatingAction(
            isVisible: auth.isSignedIn,
            systemImage: auth.isAdmin ? "square.and.pencil" : "qrcode",
            label: auth.isAdmin ? "Announce" : "Share",
            voiceOverLabel: auth.isAdmin ? "New announcement" : "Share your friend code"
        ) {
            if auth.isAdmin { showComposer = true } else { showFriendCode = true }
        }
        .toolbar {
            if !auth.isSignedIn {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sign in") { showAuthSheet = true }
                }
            }
        }
        .sheet(isPresented: $showComposer) {
            AnnouncementComposerView(existing: nil) { Task { await reload() } }
        }
        .sheet(item: $editing) { announcement in
            AnnouncementComposerView(existing: announcement) { Task { await reload() } }
        }
        .sheet(isPresented: $showAuthSheet) { AuthFlowView() }
        .sheet(item: $schedulingUnpin) { announcement in
            // A writing sheet, so NOT DismissableSheet: it carries Cancel and
            // "Schedule" rather than a Done that would have already happened.
            UnpinDateSheet(announcement: announcement) { date in
                AnnouncementActions(toasts: toasts).setPin(
                    announcement,
                    pinned: true,
                    until: date,
                    clearSchedule: date == nil
                ) { _ in Task { await reload() } }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showFriendCode) {
            // Compact on purpose: it is a code, two buttons and a sentence, and a
            // full-height sheet for that reads as a screen the member has to get
            // back out of rather than as a card they hold up.
            DismissableSheet { ShareFriendCodeSheet(code: auth.user?.friendCode) }
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog(
            "Delete this announcement?",
            isPresented: .init(get: { pendingDelete != nil },
                               set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let target = pendingDelete { delete(target) }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
        .task { if loader.items.isEmpty { await reload() } }
        // A signed-in member sees a different feed (vetted rows + read state),
        // so the feed is refetched whenever auth state flips rather than left
        // showing the signed-out view behind a signed-in session.
        .onChange(of: auth.isSignedIn) { _, _ in Task { await reload() } }
        // Deep link from an announcement push. Consumed once so a second drain
        // can't re-push the same detail screen.
        .onChange(of: appState.pendingAnnouncementId) { _, id in
            guard id != nil else { return }
            appState.announcementPath = id.map { [$0] } ?? []
            appState.pendingAnnouncementId = nil
        }
    }

    // MARK: Cards

    private var signedOutCard: some View {
        FWBCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("You're browsing signed out")
                    .font(Theme.Typography.rowTitle)
                Text("Sign in to see members-only announcements, channels, events and private chat.")
                    .font(Theme.Typography.preview)
                    .foregroundStyle(.secondary)
                Button("Sign in or create an account") { showAuthSheet = true }
                    .buttonStyle(FWBPrimaryButtonStyle())
                    .accessibilityIdentifier("home.signInCTA")
                    .padding(.top, Theme.Spacing.xs)
            }
        }
    }

    private func vettingStatusCard(_ user: AuthUser) -> some View {
        FWBCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack {
                    Text("Membership")
                        .font(Theme.Typography.rowTitle)
                    Spacer()
                    StatusBadge(user.vettingLabel, color: Theme.Colors.caution)
                }
                // Vetting comes from a Luma event check-in (PLAN.md §4.5/§4.6);
                // there is nothing for the member to fill in, so the copy says
                // so rather than implying an action they can take.
                Text("You'll get full access once we've matched you to an event check-in. Announcements are open to everyone in the meantime.")
                    .font(Theme.Typography.preview)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Admin

    /// The long press. Same items as the kebab because it is the same view —
    /// `AnnouncementMenuItems` is the single definition, so the two surfaces
    /// cannot drift apart.
    @ViewBuilder
    private func adminMenu(for announcement: Announcement) -> some View {
        if auth.isAdmin {
            AnnouncementMenuItems(announcement: announcement, handlers: handlers(for: announcement))
        }
    }

    private func handlers(for announcement: Announcement) -> AnnouncementMenuHandlers {
        let actions = AnnouncementActions(toasts: toasts)
        // The feed refetches rather than patching the row in place: pinning
        // REORDERS this list, and a row that changed its own pin state without
        // moving would be the wrong answer on screen.
        let reloadAfter: (Announcement?) -> Void = { _ in Task { await reload() } }
        return AnnouncementMenuHandlers(
            edit: { editing = announcement },
            publish: { actions.publish(announcement, onDone: reloadAfter) },
            unpublish: { actions.unpublish(announcement, onDone: reloadAfter) },
            pin: { actions.setPin(announcement, pinned: true, onDone: reloadAfter) },
            unpin: { actions.setPin(announcement, pinned: false, onDone: reloadAfter) },
            scheduleUnpin: { schedulingUnpin = announcement },
            confirmDelete: { pendingDelete = announcement })
    }

    private func delete(_ announcement: Announcement) {
        pendingDelete = nil
        AnnouncementActions(toasts: toasts).delete(announcement) { Task { await reload() } }
    }

    private func reload() async {
        // Admins read the admin list, which is the only feed that includes
        // drafts; everyone else reads the member or public feed.
        let includeDrafts = auth.isAdmin
        await loader.loadFirst { page, per in
            try await APIClient.shared.announcementsFeed(
                page: page, per: per, includeDrafts: includeDrafts)
        }
    }
}
