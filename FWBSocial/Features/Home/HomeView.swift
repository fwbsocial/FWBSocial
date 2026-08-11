import SwiftUI

/// The Home tab (PLAN.md §5.3 / §4.1) — the announcements feed, plus the
/// signed-out and vetting-status cards. Works without a session by design.
struct HomeView: View {
    var body: some View {
        AnnouncementsFeedView()
    }
}

#Preview {
    NavigationStack { HomeView() }
        .environment(AppState.shared)
        .environment(ToastCenter())
}
