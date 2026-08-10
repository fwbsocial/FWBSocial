import SwiftUI

/// Placeholder for the Channels tab (PLAN.md §5.3 / §4.2): channel browser →
/// feed → post detail → composer. Server-side plaintext, fully moderatable.
struct ChannelsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                SectionHeader(title: "Channels", subtitle: "Forum channels with per-channel permissions.", eyebrow: "Community")
                EmptyStateView(
                    icon: "bubble.left.and.bubble.right",
                    title: "No channels yet",
                    message: "Admin-curated channels (vetted / private) will list here once the forum backend lands.")
            }
            .padding()
        }
        .navigationTitle("Channels")
    }
}

#Preview {
    NavigationStack { ChannelsView() }
}
