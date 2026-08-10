import Foundation
import Observation

// MARK: - Tabs
//
// PLAN.md §5.3: Home / Channels / Events / Chat / Profile, plus a trailing-
// separated Settings tab (`Tab(role: .search)` house convention — see
// `RootTabView`). No global search tab; member lookup lives inside the
// friending / new-conversation flows only (§4.8), out of scope for this
// scaffold.

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

/// Root app-wide state: current tab selection and a landing spot for
/// push-driven navigation (`PushCoordinator.drain(appState:)`). Placeholder
/// scope only — no feature state lives here yet.
@Observable
@MainActor
final class AppState {
    static let shared = AppState()

    var selectedTab: FWBTab = .home

    private init() {}
}
