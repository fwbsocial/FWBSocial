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

// MARK: - Feature flags
//
// Which tabs exist yet.
//
// The plan's shell is Home / Channels / Events / Chat / Profile + Settings
// (§5.3), and that is still the target. But at Phase 3 the middle three have no
// feature behind them, and six tabs is one more than iPhone's bar holds — iOS
// collapses the overflow into "More", which put **Profile** there. Profile is
// where sign-out and account deletion live, and Guideline 5.1.1(v) expects
// deletion to be findable; burying it behind "More" so that three empty
// placeholders can sit in the bar is the wrong trade for a build that goes to
// the commissioner and, later, to a reviewer.
//
// So each tab is gated on its feature actually existing. Flip a flag the day the
// phase lands — that is the whole change, and `RootTabView` needs no edit.
nonisolated enum FWBFeatures {
    /// Phase 4 (PLAN.md §4.2).
    static let channels = false
    /// Phase 2/7 — Luma events and post-event friending (§4.5, §7).
    static let events = false
    /// Phase 6 — E2EE chat (§4.3).
    static let chat = false
}

extension FWBTab {
    /// Whether this tab has a feature behind it yet.
    var isEnabled: Bool {
        switch self {
        case .channels: return FWBFeatures.channels
        case .events:   return FWBFeatures.events
        case .chat:     return FWBFeatures.chat
        case .home, .profile, .settings: return true
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
