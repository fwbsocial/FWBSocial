import SwiftUI

/// Placeholder for the Events tab (PLAN.md §5.3 / §2.7): upcoming + past Luma
/// events, post-event attendee-match, vetting status.
struct EventsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                SectionHeader(title: "Events", subtitle: "Luma events + vetting status.", eyebrow: "Attend")
                EmptyStateView(
                    icon: "calendar",
                    title: "No events yet",
                    message: "Upcoming and past events synced from Luma will list here.")
            }
            .padding()
        }
        .navigationTitle("Events")
    }
}

#Preview {
    NavigationStack { EventsView() }
}
