import Foundation
import Observation

// MARK: - Tabs
//
// PLAN.md §5.3: Home / Channels / Events / Chat / Profile, plus a trailing-
// separated Settings tab (`Tab(role: .search)` house convention — see
// `RootTabView`). No global search tab; member lookup lives inside the
// friending / new-conversation flows only (§4.8, and commissioner Q9 removes
// member search from v1 entirely).

enum FWBTab: String, CaseIterable, Identifiable, Hashable {
    case home
    case channels
    case events
    case chat
    case profile
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:     return "Home"
        case .channels: return "Channels"
        case .events:   return "Events"
        case .chat:     return "Chat"
        case .profile:  return "Profile"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home:     return "house"
        case .channels: return "bubble.left.and.bubble.right"
        case .events:   return "calendar"
        case .chat:     return "lock.shield"
        case .profile:  return "person.crop.circle"
        case .settings: return "gearshape"
        }
    }
}

/// Root app-wide state: tab selection, the Home tab's navigation path, and the
/// landing spot for push-driven navigation (`PushCoordinator.drain(appState:)`).
@Observable
@MainActor
final class AppState {
    static let shared = AppState()

    var selectedTab: FWBTab = .home

    /// The Home tab's `NavigationStack` path — announcement ids. Owned here
    /// rather than inside the view so a push can push a detail screen onto a tab
    /// that has not been visited yet, and so switching tabs doesn't discard it.
    var announcementPath: [String] = []

    /// Set by `PushCoordinator` when a notification names an announcement.
    /// The feed consumes it and clears it, so a second drain can't re-navigate.
    var pendingAnnouncementId: String?

    /// True while the auth sheet should be up. Any screen can raise it.
    var isPresentingAuth = false

    private init() {}

    /// Route to an announcement from a notification tap.
    func openAnnouncement(id: String) {
        selectedTab = .home
        pendingAnnouncementId = id
    }
}
