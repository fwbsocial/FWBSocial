import SwiftUI

/// Placeholder for the Chat tab (PLAN.md §5.3 / §4.3): conversation list (1:1 +
/// group), server-authoritative unread badge. Full Cove E2EE port lands in a
/// later phase — this scaffold proves the tab shell + `GroupedBubbleShape`
/// compile, nothing more.
struct ChatListView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                SectionHeader(title: "Chat", subtitle: "End-to-end encrypted, post-quantum wrapped.", eyebrow: "Private")
                EmptyStateView(
                    icon: "lock.shield",
                    title: "No conversations yet",
                    message: "1:1 and group chats will list here once the Cove E2EE client is ported.")
            }
            .padding()
        }
        .navigationTitle("Chat")
    }
}

#Preview {
    NavigationStack { ChatListView() }
}
