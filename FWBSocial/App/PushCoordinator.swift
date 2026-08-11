import UIKit
import UserNotifications
import OSLog

private let pushLog = Logger(subsystem: "events.fwb.social", category: "Push")

// MARK: - Pending push route
//
// A tapped notification can be delivered before the SwiftUI scene's `.onReceive`
// subscription exists (cold launch). So the AppDelegate hands the route to
// `PushCoordinator`, which BOTH posts `.fwbPushPending` (warm case) and stashes
// it in `pending` (cold case). `FWBSocialApp` drains `pending` on launch and on
// every `.fwbPushPending` — whichever fires first wins; the other no-ops.
// Ported from Flux's `App/PushCoordinator.swift` (PLAN.md §5.2); routing
// categories are placeholders — the chat/channel/announcement push shapes land
// with those features (PLAN.md §4.2, §4.3.5).

enum PendingPush: Sendable, Equatable {
    case tab(FWBTab)
    /// An announcement push carries `announcement_id`; tapping it opens that
    /// announcement's detail screen, not just the Home tab (PLAN.md §4.1).
    case announcement(id: String)
    /// A chat push carries `conversation_id` and `message_id` and nothing else —
    /// it CANNOT carry a preview, because the server holds ciphertext (§4.3.5).
    /// The body the member reads is produced by the notification extension, on
    /// device; this is only the tap route.
    case conversation(id: UUID)
    /// The friends list, which lives inside Profile — now a sheet rather than a
    /// tab (owner navigation directive).
    case profile
    /// A post-event friending window just opened. Carries `luma_event_id` so the
    /// tap lands on the roster, not the tab — the window is 48 hours long and this
    /// push is the only announcement of it.
    case friendingWindow(lumaEventId: String)
    /// A second device registered and is waiting to be approved. This push is the
    /// backstop, not an optimisation: the WebSocket `device_added` frame reaches
    /// only a foregrounded device (§4.3.3).
    case devices
}

extension Notification.Name {
    static let fwbPushPending = Notification.Name("events.fwb.social.pushPending")
}

// MARK: - PushCoordinator
//
// Owns the APNs token lifecycle and auth-gated backend registration. The token
// can arrive from APNs before the user is signed in, so we cache it and POST
// only once `AuthService` reports `isSignedIn` — re-invoked post-restoreSession
// and post-login. `registeredToken` de-dupes repeat POSTs of the same token.

@MainActor
final class PushCoordinator {
    static let shared = PushCoordinator()
    private init() {}

    /// The APNs topic the backend targets — MUST be the bundle id exactly.
    private let appIdentifier = FWBConfig.bundleId

    /// Last hex token APNs handed us (may predate sign-in).
    private var cachedToken: String?
    /// Last token successfully POSTed to the backend (de-dupe guard).
    private var registeredToken: String?
    /// A registration POST already in flight. Without this, the two callers that
    /// legitimately fire at launch — the scene's `.task` and the `isSignedIn`
    /// change that `restoreSession()` triggers — both read `registeredToken` as
    /// nil before either finishes, and the same token is POSTed twice.
    private var registrationInFlight = false
    /// Authorization has already been requested this session. The prompt itself
    /// is idempotent, but asking twice is two round trips for nothing.
    private var didRequestAuthorization = false

    /// A route from a tapped notification awaiting the scene (see PendingPush).
    private(set) var pending: PendingPush?

    // MARK: Registration lifecycle

    /// Ask for alert/badge/sound authorization, then register for remote
    /// notifications regardless of the grant (registration itself always
    /// succeeds and gives us a token; the grant only gates alert display).
    func requestAuthorizationAndRegister() {
        guard !didRequestAuthorization else {
            // Already asked — just make sure the backend has the token.
            syncRegistration()
            return
        }
        didRequestAuthorization = true
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .badge, .sound])
                pushLog.debug("Notification authorization granted=\(granted)")
            } catch {
                pushLog.error("Notification authorization request failed: \(error.localizedDescription)")
            }
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// APNs handed us a fresh device token (hex-encoded). Cache it and try to
    /// register with the backend if we're already signed in.
    func deviceTokenDidUpdate(_ hex: String) {
        cachedToken = hex
        pushLog.debug("APNs device token \(hex.prefix(8), privacy: .public)…")
        syncRegistration()
    }

    /// POST the cached token when signed in; no-op if there's no token, we're
    /// signed out, or this exact token is already registered. Called on token
    /// update, after `restoreSession()`, and after a successful login.
    func syncRegistration() {
        guard let token = cachedToken else { return }
        guard AuthService.shared.isSignedIn else { return }
        guard token != registeredToken else { return }
        guard !registrationInFlight else { return }
        registrationInFlight = true
        Task {
            defer { registrationInFlight = false }
            do {
                try await APIClient.shared.registerPushDevice(
                    token: token,
                    bundleId: appIdentifier,
                    environment: FWBConfig.apnsEnvironment)
                registeredToken = token
                pushLog.debug("Registered device token with backend")
            } catch {
                pushLog.error("register-device failed: \(error.localizedDescription)")
            }
        }
    }

    /// Best-effort unregister on sign-out. Captures the CURRENT bearer token
    /// synchronously (the caller — `AuthService.signOut()` — clears the token
    /// immediately after, and the async DELETE would otherwise 401), then fires
    /// the DELETE with that captured auth via a one-off request.
    func unregister() {
        guard let token = cachedToken ?? registeredToken else { return }
        guard let bearer = APIClient.shared.accessToken else { registeredToken = nil; return }
        let baseURL = APIClient.shared.baseURL
        registeredToken = nil
        didRequestAuthorization = false
        Task {
            struct Body: Encodable { let token: String }
            var req = URLRequest(url: URL(string: baseURL + "/api/push/devices")!)
            req.httpMethod = "DELETE"
            req.setValue(FWBConfig.appId, forHTTPHeaderField: "X-App-Id")
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? FWBJSON.encoder.encode(Body(token: token))
            req.timeoutInterval = 15
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    // MARK: Routing

    /// Decide where a tapped notification should take the user.
    ///
    /// `userInfo` values are flattened onto the APS payload by the server's
    /// `PushService.Payload` — the client reads `userInfo["announcement_id"]`
    /// directly, not nested under an `extra` key.
    ///
    /// Category-only routing is the fallback: an announcement push that carries
    /// an id opens that announcement; one that doesn't still lands on Home.
    /// Chat and channel categories are placeholders until those features exist.
    func route(category: String, userInfo: [String: String] = [:]) {
        switch category {
        case "fwb_announcement":
            if let id = userInfo["announcement_id"], !id.isEmpty {
                enqueue(.announcement(id: id))
            } else {
                enqueue(.tab(.home))
            }
        // The chat categories are the server's own literals — `ChatPushService`
        // sends `CHAT_MESSAGE`, `ChatDeviceController` sends `DEVICE_APPROVAL`,
        // and `FriendsController` sends `FRIEND_REQUEST` / `FRIEND_ACCEPTED`.
        case "CHAT_MESSAGE":
            if let raw = userInfo["conversation_id"], let id = UUID(uuidString: raw) {
                enqueue(.conversation(id: id))
            } else {
                enqueue(.tab(.chat))
            }
        case "FRIENDING_WINDOW":
            if let id = userInfo["luma_event_id"], !id.isEmpty {
                enqueue(.friendingWindow(lumaEventId: id))
            } else {
                enqueue(.tab(.events))
            }
        case "DEVICE_APPROVAL":
            enqueue(.devices)
        case "FRIEND_REQUEST", "FRIEND_ACCEPTED":
            enqueue(.profile)
        case "fwb_channel_post":
            enqueue(.tab(.channels))
        default:
            // A push with no category but an announcement id is still routable —
            // the payload is what matters, the category is just a hint.
            if let id = userInfo["announcement_id"], !id.isEmpty {
                enqueue(.announcement(id: id))
            }
        }
    }

    private func enqueue(_ p: PendingPush) {
        pending = p
        NotificationCenter.default.post(name: .fwbPushPending, object: nil)
    }

    /// Consume any pending route against the live `AppState`. Idempotent —
    /// clears `pending` so the warm (`.onReceive`) and cold (launch `.task`)
    /// drains don't double-fire.
    func drain(appState: AppState) {
        guard let p = pending else { return }
        pending = nil
        switch p {
        case .tab(let tab):
            appState.selectedTab = tab
        case .announcement(let id):
            appState.openAnnouncement(id: id)
        case .conversation(let id):
            appState.openConversation(id: id)
        case .friendingWindow(let lumaEventId):
            appState.openFriendingWindow(lumaEventId: lumaEventId)
        case .profile:
            appState.isPresentingProfile = true
        case .devices:
            appState.selectedTab = .chat
            appState.isPresentingDevices = true
        }
    }
}

// MARK: - AppDelegate
//
// Pure-SwiftUI app has no AppDelegate of its own; this is wired via
// `@UIApplicationDelegateAdaptor` in `FWBSocialApp`. It owns the two things
// that require UIKit hooks: becoming the notification-center delegate at
// launch, and receiving the APNs device token. Under Swift 6 default-MainActor
// isolation the `UIApplicationDelegate` methods are MainActor (the protocol
// is), but the `UNUserNotificationCenterDelegate` methods are NOT — they're
// marked `nonisolated` and hop to the MainActor via `Task { @MainActor in … }`.

final class FWBAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        UNUserNotificationCenter.current().setBadgeCount(0)
    }

    // MARK: APNs token

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        PushCoordinator.shared.deviceTokenDidUpdate(hex)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        pushLog.error("APNs registration failed: \(error.localizedDescription)")
    }

    // MARK: UNUserNotificationCenterDelegate (nonisolated — see note above)

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .badge, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        let category = content.categoryIdentifier
        // `userInfo` is `[AnyHashable: Any]` and not Sendable, so it is flattened
        // to the string pairs we actually route on BEFORE hopping to the
        // MainActor — carrying the dictionary across would not compile under
        // strict concurrency, and shouldn't.
        let info: [String: String] = content.userInfo.reduce(into: [:]) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String {
                result[key] = value
            }
        }
        Task { @MainActor in
            PushCoordinator.shared.route(category: category, userInfo: info)
        }
        completionHandler()
    }
}
