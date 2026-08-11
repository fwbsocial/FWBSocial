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
    @State private var error: String?
    @State private var hasLoaded = false

    var body: some View {
        Group {
            if !auth.isVettedForForum && hasLoaded && channels.isEmpty {
                pendingState
            } else if channels.isEmpty && hasLoaded && error == nil {
                EmptyStateView(
                    icon: "bubble.left.and.bubble.right",
                    title: "No channels yet",
                    message: "Channels are created by admins. One will show up here as soon as it does.")
            } else {
                list
            }
        }
        .navigationTitle("Channels")
        .task {
            await blocks.loadIfNeeded()
            await loadIfNeeded()
        }
        .refreshable { await load() }
    }

    // MARK: - List

    private var list: some View {
        List {
            if let error {
                Section { FormErrorText(message: error) }
            }

            ForEach(channels) { channel in
                NavigationLink {
                    ChannelFeedView(channel: channel)
                } label: {
                    ChannelRow(channel: channel)
                }
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
        .listStyle(.insetGrouped)
    }

    /// A `pending` member gets 403 on every `/api/channels/*` route. Plan §4.6:
    /// "Pending members get a real app… Never a blank screen." So the tab
    /// explains itself rather than showing an error or an empty list.
    private var pendingState: some View {
        EmptyStateView(
            icon: "clock.badge.checkmark",
            title: "Channels unlock once you're vetted",
            message: "Check in at an fwb social event and your account is approved automatically. You'll get the channels the moment that happens.")
    }

    // MARK: - Load

    private func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load()
    }

    private func load() async {
        guard auth.isSignedIn else { return }
        isLoading = true
        error = nil
        do {
            channels = try await APIClient.shared.channels()
            hasLoaded = true
        } catch let APIError.httpError(code, _) where code == 403 {
            // Not vetted yet — an expected answer, not a failure to report.
            channels = []
            hasLoaded = true
        } catch {
            guard !isCancellationError(error) else { isLoading = false; return }
            self.error = error.localizedDescription
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

                    if channel.isPrivate {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    if channel.isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
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

    private var accent: Color {
        guard let hex = channel.accentHex else { return Theme.Colors.brand }
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard let value = UInt32(cleaned, radix: 16) else { return Theme.Colors.brand }
        return Color(hex: value)
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
