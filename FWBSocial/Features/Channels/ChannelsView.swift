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

    @State private var channels: [Channel] = []
    @State private var isLoading = false
    // Kept unflattened so the view can distinguish an offline device from a
    // server refusal, and so the server's own sentence survives to the screen.
    @State private var loadError: Error?
    @State private var hasLoaded = false
    /// The server's own explanation for a 403, when it sent one.
    @State private var accessMessage: String?

    var body: some View {
        Group {
            if hasLoaded && channels.isEmpty && (accessMessage != nil || !auth.isVettedForForum) {
                pendingState
            } else if channels.isEmpty, hasLoaded, let failure = loadError {
                // Previously this case fell through to `list`, which drew an empty
                // List with a thin error line in it — a blank screen with a
                // footnote, and no way to retry short of a pull-to-refresh on
                // nothing.
                ErrorStateView(error: failure) { Task { await load() } }
            } else if channels.isEmpty && hasLoaded && loadError == nil {
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
        .task {
            await blocks.loadIfNeeded()
            await loadIfNeeded()
        }
        .refreshable { await load() }
    }

    // MARK: - List

    private var list: some View {
        List {
            Group {
                // Only over content — an empty list with an error takes the whole
                // surface above, where the retry lives.
                if let loadError {
                    Section { InlineErrorRow(message: loadError.fwbMessage) { Task { await load() } } }
                }

                ForEach(channels) { channel in
                    NavigationLink {
                        ChannelFeedView(channel: channel)
                            .fwbAppThemeSurface()
                    } label: {
                        ChannelRow(channel: channel)
                    }
                    .accessibilityIdentifier("channel.\(channel.slug)")
                }

                if isLoading && channels.isEmpty {
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
            icon: accessMessage == nil ? "clock.badge.checkmark" : "lock.circle",
            title: accessMessage == nil ? "Channels unlock once you're vetted" : "Channels aren't available",
            message: accessMessage
                ?? "Check in at an fwb social event and your account is approved automatically. You'll get the channels the moment that happens.")
    }

    // MARK: - Load

    private func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load()
    }

    private func load() async {
        guard auth.isSignedIn else { return }
        isLoading = true
        loadError = nil
        do {
            channels = try await APIClient.shared.channels()
            hasLoaded = true
        } catch let APIError.httpError(code, message) where code == 403 {
            // Not vetted (or banned, or revoked) — an expected answer, not a
            // failure to report. The server's message says which.
            channels = []
            accessMessage = message
            hasLoaded = true
        } catch {
            guard !isCancellationError(error) else { isLoading = false; return }
            self.loadError = error
            hasLoaded = true
        }
        isLoading = false
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
