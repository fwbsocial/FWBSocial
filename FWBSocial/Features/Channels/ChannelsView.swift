import SwiftUI

// MARK: - Channel list
//
// The Channels tab (plan §4.2, §5.3). Admin-curated channels, each carrying the
// caller's **server-resolved** role — this screen never computes a permission,
// it only draws the ones it is handed.
//
// Channels the caller cannot see are omitted by the server rather than returned
// with a null role, so there is no "locked channel" row to render here. Plan §4.2
// is explicit about why: "a row with a name and no access still leaks the
// channel's existence and title, which for a community like this is exactly the
// kind of thing a private channel exists to avoid."

struct ChannelsView: View {

    @Environment(ToastCenter.self) private var toasts
    @State private var auth = AuthService.shared
    @State private var blocks = BlockStore.shared

    /// The list, the server-resolved roles and the 403 explanation all live in
    /// the store, warmed at launch by `AppPrefetch` (owner directive 2026-08-11:
    /// a member never sees a tab load). They were `@State` here, which meant
    /// nothing existed until the first visit and every return to the tab
    /// refetched from scratch, flashing the empty state on the way.
    ///
    /// The store keeps the failure unflattened for the same reason this view
    /// did: an offline device and a server refusal are different problems, and
    /// the server's own sentence is the content of the vetting state.
    @State private var store = ChannelsStore.shared

    // The tab's contextual action (owner directive 2026-08-11). Two different
    // actions behind one slot, because "what can you start from a list of
    // channels" has two answers depending on who is asking.
    @State private var isCreatingChannel = false
    @State private var isPickingChannel = false
    /// Chosen in the picker, presented after it closes. Two sheets cannot swap in
    /// one runloop turn, so the composer waits for `onDismiss` rather than racing
    /// the picker's dismissal and being swallowed.
    @State private var pendingPostChannel: Channel?
    @State private var postTarget: Channel?

    /// An admin always has something to do here. A member has something to do here
    /// once the forum is open to them at all — a `pending` member gets 403 on every
    /// `/api/channels/*` route and is looking at the vetting screen, so the slot
    /// stays empty rather than offering them a composer that cannot post.
    private var hasContextualAction: Bool {
        auth.isSignedIn && (auth.isAdmin || auth.isVettedForForum)
    }

    var body: some View {
        Group {
            if store.hasLoaded && store.channels.isEmpty
                && (store.accessMessage != nil || !auth.isVettedForForum) {
                pendingState
            } else if store.channels.isEmpty, store.hasLoaded, let failure = store.loadError {
                // Previously this case fell through to `list`, which drew an empty
                // List with a thin error line in it — a blank screen with a
                // footnote, and no way to retry short of a pull-to-refresh on
                // nothing.
                ErrorStateView(error: failure) { Task { await store.refresh() } }
            } else if store.channels.isEmpty && store.hasLoaded && store.loadError == nil {
                EmptyStateView(
                    icon: "bubble.left.and.bubble.right",
                    title: "No channels yet",
                    message: "Channels are created by admins. One will show up here as soon as it does.")
            } else {
                list
            }
        }
        .navigationTitle("Channels")
        .rootSurfaceChrome()
        .floatingAction(
            isVisible: hasContextualAction,
            systemImage: auth.isAdmin ? "plus.rectangle.on.rectangle" : "plus.bubble",
            label: auth.isAdmin ? "Add" : "New",
            voiceOverLabel: auth.isAdmin ? "New channel" : "New post"
        ) {
            if auth.isAdmin { isCreatingChannel = true } else { isPickingChannel = true }
        }
        .sheet(isPresented: $isCreatingChannel) {
            // The list is refetched rather than having the new channel appended:
            // the admin route answers from the ADMIN's point of view
            // (`effective_role: moderator`, `muted: false`), which is not what this
            // list draws.
            ChannelCreateView { _ in Task { await store.refresh() } }
        }
        .sheet(isPresented: $isPickingChannel, onDismiss: {
            guard let chosen = pendingPostChannel else { return }
            pendingPostChannel = nil
            postTarget = chosen
        }) {
            DismissableSheet {
                ChannelPickerSheet(channels: store.postableChannels) { channel in
                    pendingPostChannel = channel
                    isPickingChannel = false
                }
            }
        }
        .sheet(item: $postTarget) { channel in
            PostComposerView(channel: channel) { _ in Task { await store.refresh() } }
        }
        // Warm, not load: `AppPrefetch` already fired both of these at launch,
        // and each is a no-op once it holds data. Entering the tab a second time
        // does nothing visible at all.
        .task {
            await blocks.loadIfNeeded()
            await store.warm()
        }
        .refreshable { await store.refresh() }
    }

    // MARK: - List

    private var list: some View {
        List {
            Group {
                // Only over content — an empty list with an error takes the whole
                // surface above, where the retry lives.
                if let failure = store.loadError {
                    Section {
                        InlineErrorRow(message: failure.fwbMessage) {
                            Task { await store.refresh() }
                        }
                    }
                }

                ForEach(store.channels) { channel in
                    NavigationLink {
                        ChannelFeedView(channel: channel)
                            .fwbAppThemeSurface()
                    } label: {
                        ChannelRow(channel: channel)
                    }
                    .accessibilityIdentifier("channel.\(channel.slug)")
                }

                // The ONE spinner, and only before any data has ever arrived.
                // Every later refresh happens behind the rows (`ChannelsStore`).
                if store.isInitialLoading && store.channels.isEmpty {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                }
            }
            // An inset-grouped list draws an opaque `secondarySystemGroupedBackground`
            // per row — a system-grey card on top of the theme's own backdrop. This
            // is the same trait the two Form screens already set and this list
            // simply never did; without it, Channels was the one signed-in surface
            // where light Clubhouse had no white boxes on it. The `Group` is what
            // makes a per-ROW trait reach every row from one line.
            .fwbThemedRows()
        }
        .listStyle(.insetGrouped)
    }

    /// A `pending` member gets 403 on every `/api/channels/*` route. Plan §4.6:
    /// "Pending members get a real app… Never a blank screen." So the tab
    /// explains itself rather than showing an error or an empty list.
    ///
    /// The sentence comes from the server when it sent one. `RequireVettedMember`
    /// distinguishes pending / banned / revoked / rejected and writes the right
    /// message for each; showing our own copy for all four would tell a banned
    /// member to go check in at an event.
    private var pendingState: some View {
        EmptyStateView(
            icon: store.accessMessage == nil ? "clock.badge.checkmark" : "lock.circle",
            title: store.accessMessage == nil ? "Channels unlock once you're vetted" : "Channels aren't available",
            message: store.accessMessage
                ?? "Check in at an fwb social event and your account is approved automatically. You'll get the channels the moment that happens.")
    }

}

// MARK: - Row

private struct ChannelRow: View {
    let channel: Channel

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.16))
                    .frame(width: 40, height: 40)
                Image(systemName: channel.symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(accent)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(channel.displayName)
                        .font(Theme.Typography.rowTitle)
                        .foregroundStyle(.primary)

                    // Both glyphs carry information no other part of the row
                    // repeats, so they are labelled rather than hidden.
                    if channel.isPrivate {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Private channel")
                    }
                    if channel.isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Muted")
                    }
                }

                if let description = channel.description, !description.isEmpty {
                    Text(description)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    // Data uses numerals; "no posts yet" spells the zero.
                    Text(channel.posts == 0
                         ? "No posts yet"
                         : "\(channel.posts) post\(channel.posts == 1 ? "" : "s")")
                        .font(Theme.Typography.micro)
                        .foregroundStyle(.secondary)

                    if let badge = channel.roleBadge {
                        Text("· \(badge)")
                            .font(Theme.Typography.micro)
                            .foregroundStyle(Theme.Colors.brand)
                    }
                    if channel.archived {
                        Text("· Archived")
                            .font(Theme.Typography.micro)
                            .foregroundStyle(Theme.Colors.caution)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// The channel's admin-chosen accent, made safe for whichever appearance is on.
    ///
    /// `accentHex` is a single value typed into an admin form, with no dark
    /// variant and nothing checking it against a background. A deep colour picked
    /// to look right in light mode is close to invisible on a dark background, and
    /// a pale one washes out on a light one — the row's title glyph and its
    /// coloured disc both go with it. Rather than reject the admin's colour, its
    /// luminance is clamped into a band that stays legible on both, which keeps
    /// the hue they chose and only moves how light it is.
    private var accent: Color {
        guard let hex = channel.accentHex else { return Theme.Colors.brand }
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
            return Theme.Colors.brand
        }
        return Color(uiColor: UIColor { traits in
            let base = UIColor(
                red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1)
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            guard base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
                return base
            }
            // On a dark background a colour needs to be light enough to read; on a
            // light one, dark enough. The bands overlap, so a mid-tone accent is
            // returned untouched in both.
            let clamped = traits.userInterfaceStyle == .dark
                ? max(brightness, 0.62)
                : min(brightness, 0.72)
            return UIColor(hue: hue, saturation: saturation, brightness: clamped, alpha: alpha)
        })
    }
}

// MARK: - Vetting helper

extension AuthService {
    /// Whether the forum is expected to be reachable. A **display** decision
    /// only: `RequireVettedMember` re-reads the row on every request and is the
    /// thing that actually decides, so this must never be the only gate on
    /// anything that matters.
    var isVettedForForum: Bool {
        guard let user else { return false }
        return user.isVetted || user.isAdmin || user.isModerator
    }
}

#Preview {
    NavigationStack { ChannelsView() }
        .environment(ToastCenter())
}
