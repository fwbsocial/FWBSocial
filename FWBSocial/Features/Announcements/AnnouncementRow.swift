import SwiftUI

// MARK: - Feed row

struct AnnouncementRow: View {
    let announcement: Announcement
    /// Admins get the kebab overlaid on this card and the pin's end date in the
    /// footer. A member has no idea what a pin is and no way to change one, so
    /// showing them a schedule would be noise about a control they do not have.
    var isAdmin: Bool = false

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
                    // The kebab is drawn by the feed as an overlay on the
                    // NavigationLink — it cannot live inside this card, because a
                    // control inside a link's label never gets the tap. This
                    // reserves its width so the title never runs under it.
                    if isAdmin {
                        Spacer().frame(width: 32)
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
                    if isAdmin, let schedule = announcement.pinScheduleLabel {
                        Label(schedule, systemImage: "calendar.badge.clock")
                            .foregroundStyle(Theme.Colors.brand)
                    }
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}
