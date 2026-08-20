import SwiftUI

// MARK: - Announcement detail
//
// Reachable three ways: tapping a feed row, a push deep link (`ANNOUNCEMENT`
// with an `announcement_id`), and — once the web side exists — a universal link.
// The push case can arrive on a cold launch before the feed has ever loaded, so
// this screen must be able to fetch its own subject rather than assuming a row
// was handed to it. `preloaded` is an optimisation, not a requirement.
//
// # The screen belongs to `announcementId`, and nothing else
//
// Everything drawn here comes from `announcement`, which is `@State` — and state
// survives the view being handed a NEW `announcementId`. That happens: a
// `NavigationStack` destination is positional, so replacing the element already
// at `announcementPath[0]` (which is exactly what an announcement push does while
// a detail is open — `AnnouncementsFeedView`'s `pendingAnnouncementId` handler)
// updates this view in place rather than building a fresh one. With an unkeyed
// `.task` the load never re-ran, so the stack said one announcement and the
// screen showed the previous one — the wrong announcement, under the right id.
//
// So the load is keyed on `announcementId`: the id changing cancels the old run,
// re-seeds from the new `preloaded`, and fetches again. The two guards in
// `load()` close the other half of it — a response that is late, or that is not
// for the id being asked about, is dropped rather than written over the screen.

struct AnnouncementDetailView: View {
    let announcementId: String
    var preloaded: Announcement?

    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var auth = AuthService.shared
    @State private var announcement: Announcement?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var editing: Announcement?
    @State private var pendingDelete: Announcement?
    @State private var schedulingUnpin: Announcement?

    var body: some View {
        ScrollView {
            if let announcement {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        if announcement.pinned {
                            // Admins see when it lapses; a member has no pin
                            // control, so the date would be noise to them.
                            Label(
                                (auth.isAdmin ? announcement.pinScheduleLabel : nil) ?? "Pinned",
                                systemImage: "pin.fill")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.brand)
                        }
                        Text(announcement.displayTitle)
                            .font(Theme.Typography.display)
                            .multilineTextAlignment(.leading)

                        HStack(spacing: Theme.Spacing.sm) {
                            if let author = announcement.authorName {
                                Text(author)
                            }
                            if let timestamp = announcement.timestamp {
                                if announcement.authorName != nil { Text("·") }
                                Text(timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                            }
                            if announcement.isVettedOnly {
                                StatusBadge("Members", color: Theme.Colors.caution)
                            }
                        }
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                    }

                    Divider()

                    // Body is markdown per PLAN.md §2.2. `AttributedString`'s
                    // inline-markdown parsing covers emphasis and links, which is
                    // what an announcement actually uses; block-level markdown
                    // (headings, lists) renders as literal text and is a known
                    // limitation to revisit if admins start reaching for it.
                    Text(markdown(announcement.displayBody))
                        .font(Theme.Typography.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(Theme.Spacing.xl)
            } else if isLoading {
                ProgressView()
                    .controlSize(.large)
                    .padding(.top, Theme.Spacing.xxl * 2)
            } else if let errorMessage {
                EmptyStateView(
                    icon: "exclamationmark.triangle",
                    title: "Couldn't open this",
                    message: errorMessage,
                    actionTitle: "Try again",
                    action: { Task { await load() } })
            }
        }
        .background(Theme.Colors.background)
        .navigationTitle("Announcement")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let announcement {
                ToolbarItem(placement: .topBarTrailing) {
                    if auth.isAdmin {
                        // The kebab REPLACES the standalone share button for
                        // admins — share is one item inside it now, so the
                        // trailing corner holds one control rather than two.
                        AnnouncementKebabMenu(
                            announcement: announcement,
                            handlers: handlers(for: announcement),
                            // The bar supplies the target and the bubble; a
                            // 44pt-wide glyph in here is what made it an oval.
                            placement: .toolbar)
                    } else {
                        ShareLink(item: announcement.shareText)
                    }
                }
            }
        }
        .contextMenu {
            if auth.isAdmin, let announcement {
                AnnouncementMenuItems(announcement: announcement, handlers: handlers(for: announcement))
            }
        }
        .sheet(item: $editing) { target in
            AnnouncementComposerView(existing: target) { Task { await load() } }
        }
        .sheet(item: $schedulingUnpin) { target in
            UnpinDateSheet(announcement: target) { date in
                AnnouncementActions(toasts: toasts).setPin(
                    target, pinned: true, until: date, clearSchedule: date == nil
                ) { updated in if let updated { announcement = updated } }
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog(
            "Delete this announcement?",
            isPresented: .init(get: { pendingDelete != nil },
                               set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let target = pendingDelete else { return }
                pendingDelete = nil
                // Pops the screen: staying on the detail view of something that
                // no longer exists would 404 on the next refresh.
                AnnouncementActions(toasts: toasts).delete(target) { dismiss() }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
        // `task(id:)`, NOT `task`: this view is reused in place when the pushed
        // announcement changes underneath it, and an unkeyed task would leave the
        // previous announcement's content on screen for the new id.
        .task(id: announcementId) {
            announcement = preloaded
            await load()
            // Through the store, so the feed's dot clears the moment this screen
            // opens rather than at whatever refresh happens next — the feed no
            // longer refetches on every tab entry, so "the next refresh" could
            // be minutes away. Still fire-and-forget on the wire: failing to
            // record a read is not worth interrupting anyone over.
            await AnnouncementsStore.shared.markRead(id: announcementId)
        }
    }

    /// Built from the SAME `AnnouncementMenuItems` the feed uses; only the "and
    /// then" differs — this screen reloads the one row it is showing.
    /// `target`, not `announcement`: the parameter would otherwise shadow the
    /// @State of the same name that these closures write back into.
    private func handlers(for target: Announcement) -> AnnouncementMenuHandlers {
        let actions = AnnouncementActions(toasts: toasts)
        // Take the row the write returned rather than refetching: the member
        // detail route serves published announcements only, so a reload right
        // after "move to draft" would 404 and leave a published-looking screen.
        let apply: (Announcement?) -> Void = { updated in
            if let updated { announcement = updated }
        }
        return AnnouncementMenuHandlers(
            edit: { editing = target },
            publish: { actions.publish(target, onDone: apply) },
            unpublish: { actions.unpublish(target, onDone: apply) },
            pin: { actions.setPin(target, pinned: true, onDone: apply) },
            unpin: { actions.setPin(target, pinned: false, onDone: apply) },
            scheduleUnpin: { schedulingUnpin = target },
            confirmDelete: { pendingDelete = target })
    }

    private func markdown(_ source: String) -> AttributedString {
        (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(source)
    }

    private func load() async {
        let asked = announcementId
        isLoading = announcement == nil
        errorMessage = nil
        // In a `defer` because the guards below return early, and a screen left
        // spinning forever is a worse bug than the one they are preventing.
        defer { isLoading = false }
        do {
            let fetched = try await APIClient.shared.announcement(id: asked)
            // Two ways a right-looking response is the wrong answer: the task was
            // superseded while this was in flight (a new id was pushed), or the
            // server handed back something other than what was asked for. Either
            // way it must not become what the member is reading.
            guard !Task.isCancelled, asked == announcementId else { return }
            guard fetched.id.caseInsensitiveCompare(asked) == .orderedSame else { return }
            announcement = fetched
        } catch {
            // A preloaded row is better than an error screen — only surface the
            // failure when there's nothing at all to show.
            if announcement == nil { errorMessage = error.fwbMessage }
        }
    }
}
