import SwiftUI

// MARK: - Feed row

struct AnnouncementRow: View {
    let announcement: Announcement

    var body: some View {
        FWBCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(spacing: Theme.Spacing.sm) {
                    if announcement.pinned {
                        Image(systemName: "pin.fill")
                            .font(Theme.Typography.micro)
                            .foregroundStyle(Theme.Colors.brand)
                            // Pinning is why this row sits above the others, and the
                            // glyph was the only thing saying so — unlabelled, an
                            // SF Symbol contributes nothing to the row's description.
                            // Matches the unread dot a few lines below.
                            .accessibilityLabel("Pinned")
                    }
                    Text(announcement.displayTitle)
                        .font(Theme.Typography.rowTitle)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: Theme.Spacing.sm)
                    if announcement.isUnread {
                        Circle()
                            .fill(Theme.Colors.brand)
                            .frame(width: 8, height: 8)
                            .accessibilityLabel("Unread")
                    }
                }

                if !announcement.displayBody.isEmpty {
                    Text(announcement.displayBody)
                        .font(Theme.Typography.preview)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }

                HStack(spacing: Theme.Spacing.sm) {
                    if let timestamp = announcement.timestamp {
                        Text(timestamp, format: .relative(presentation: .named))
                    }
                    if let author = announcement.authorName {
                        Text("·")
                        Text(author)
                    }
                    if announcement.isVettedOnly {
                        StatusBadge("Members", color: Theme.Colors.caution)
                    }
                    if announcement.isDraft {
                        StatusBadge("Draft", color: Theme.Colors.caution)
                    }
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}
