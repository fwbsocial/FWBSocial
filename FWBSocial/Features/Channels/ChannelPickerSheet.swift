import SwiftUI

// MARK: - "Which channel?"
//
// The Channels tab's contextual action for a member (owner directive 2026-08-11).
// The tab root is a list of channels, so "New post" there has no channel yet —
// this is the missing half of the question, and the composer follows.
//
// **Only channels the member can actually post in.** `canPost` is the server's
// resolved role, not the channel's default (`ChannelAccess`), and offering a
// channel here that would then 403 in the composer is worse than not offering it:
// the member has already written the post by the time they find out.
//
// Presented inside a `DismissableSheet`, which supplies the `NavigationStack`, the
// theme surface and the Done button.

struct ChannelPickerSheet: View {
    /// Pre-filtered by the caller to the channels this member may post in.
    let channels: [Channel]
    var onPick: (Channel) -> Void

    var body: some View {
        Group {
            if channels.isEmpty {
                EmptyStateView(
                    icon: "text.bubble",
                    title: "No channel to post in",
                    // A comment-only member is not broken and should not be told
                    // they are — this is the normal state of a curated forum.
                    message: "You can reply in every channel you can see. Starting a thread is opened up per channel by an admin.")
            } else {
                List {
                    Section {
                        ForEach(channels) { channel in
                            Button {
                                onPick(channel)
                            } label: {
                                ChannelPickerRow(channel: channel)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("postPicker.\(channel.slug)")
                            .accessibilityLabel("Post in \(channel.displayName)")
                        }
                    } footer: {
                        // `fwbThemedRows()` wraps headers and footers along with
                        // the rows, and a footer sits on the BACKDROP rather than
                        // in the white box — without this it renders in the
                        // light-mode secondary grey on a dark canvas and is
                        // effectively invisible (observed in the simulator).
                        Text("Only the channels you can start a thread in are listed.")
                            .fwbOnCanvas()
                    }
                    .fwbThemedRows()
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("New post")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("postPicker.sheet")
    }
}

private struct ChannelPickerRow: View {
    let channel: Channel

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: channel.symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.Colors.brand)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(channel.displayName)
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(.primary)
                if let description = channel.description, !description.isEmpty {
                    Text(description)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            if channel.isPrivate {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Private channel")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
