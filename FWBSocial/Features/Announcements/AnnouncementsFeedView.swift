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
    @State private var showAuthSheet = false

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
                            AnnouncementRow(announcement: announcement)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { adminMenu(for: announcement) }
                        .task {
                            await loader.loadMoreIfNeeded(current: announcement) { page, per in
                                try await APIClient.shared.announcementsFeed(page: page, per: per)
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
        .refreshable { await reload() }
        .navigationTitle("fwb social")
        .navigationDestination(for: String.self) { id in
            AnnouncementDetailView(announcementId: id, preloaded: loader.items.first { $0.id == id })
        }
        .toolbar {
            if auth.isAdmin {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showComposer = true
                    } label: {
                        Label("New announcement", systemImage: "square.and.pencil")
                    }
                }
            }
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

    @ViewBuilder
    private func adminMenu(for announcement: Announcement) -> some View {
        if auth.isAdmin {
            Button {
                editing = announcement
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            if !announcement.isPublished {
                Button {
                    publish(announcement)
                } label: {
                    Label("Publish", systemImage: "paperplane")
                }
            }
            Button(role: .destructive) {
                pendingDelete = announcement
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func publish(_ announcement: Announcement) {
        Task {
            do {
                _ = try await APIClient.shared.publishAnnouncement(id: announcement.id)
                toasts.success("Published")
                await reload()
            } catch {
                toasts.error(error.localizedDescription)
            }
        }
    }

    private func delete(_ announcement: Announcement) {
        pendingDelete = nil
        Task {
            do {
                try await APIClient.shared.deleteAnnouncement(id: announcement.id)
                toasts.success("Deleted")
                await reload()
            } catch {
                toasts.error(error.localizedDescription)
            }
        }
    }

    private func reload() async {
        await loader.loadFirst { page, per in
            try await APIClient.shared.announcementsFeed(page: page, per: per)
        }
    }
}
