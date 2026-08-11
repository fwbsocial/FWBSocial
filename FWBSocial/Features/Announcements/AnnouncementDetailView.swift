import SwiftUI

// MARK: - Announcement detail
//
// Reachable three ways: tapping a feed row, a push deep link (`fwb_announcement`
// with an `announcement_id`), and — once the web side exists — a universal link.
// The push case can arrive on a cold launch before the feed has ever loaded, so
// this screen must be able to fetch its own subject rather than assuming a row
// was handed to it. `preloaded` is an optimisation, not a requirement.

struct AnnouncementDetailView: View {
    let announcementId: String
    var preloaded: Announcement?

    @State private var announcement: Announcement?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            if let announcement {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        if announcement.pinned {
                            Label("Pinned", systemImage: "pin.fill")
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
            if let announcement, !announcement.displayBody.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: "\(announcement.displayTitle)\n\n\(announcement.displayBody)")
                }
            }
        }
        .task {
            announcement = preloaded
            await load()
        }
    }

    private func markdown(_ source: String) -> AttributedString {
        (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(source)
    }

    private func load() async {
        isLoading = announcement == nil
        errorMessage = nil
        do {
            announcement = try await APIClient.shared.announcement(id: announcementId)
        } catch {
            // A preloaded row is better than an error screen — only surface the
            // failure when there's nothing at all to show.
            if announcement == nil { errorMessage = error.localizedDescription }
        }
        isLoading = false
    }
}
