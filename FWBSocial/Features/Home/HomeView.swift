import SwiftUI

/// Placeholder for the Home tab (PLAN.md §5.3 / §4.1): announcements feed —
/// works signed-out — plus onboarding/status cards. Feature logic lands in a
/// later phase; this scaffold just proves the tab shell + kit compile.
struct HomeView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                SectionHeader(title: "Home", subtitle: "Announcements land here.", eyebrow: "fwb social")
                EmptyStateView(
                    icon: "megaphone",
                    title: "No announcements yet",
                    message: "Published announcements will appear here — readable signed out, per App Review's Guideline 1.2 posture.")
            }
            .padding()
        }
        .navigationTitle("Home")
    }
}

#Preview {
    NavigationStack { HomeView() }
}
