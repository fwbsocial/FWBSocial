import SwiftUI

@main
struct FWBSocialApp: App {
    @UIApplicationDelegateAdaptor(FWBAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    @State private var appState = AppState.shared
    @State private var appearance = AppearanceService.shared
    @State private var toasts = ToastCenter()
    @State private var auth = AuthService.shared
    @State private var onboarding = OnboardingService.shared

    /// Onboarding covers the app only once we know who the member is AND what
    /// they still owe. Gating on `didLoad` too stops a returning member seeing a
    /// flash of the EULA they accepted months ago while `/agreements` is in
    /// flight.
    private var isPresentingOnboarding: Bool {
        auth.isSignedIn && onboarding.didLoad && !onboarding.isComplete
    }

    init() {
        // The nav-bar appearance proxy is global state, so it is set once here
        // rather than from whichever view happens to appear first.
        NavigationAppearance.apply()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(appState)
                .environment(appearance)
                .environment(toasts)
                .environment(auth)
                .environment(onboarding)
                .fwbToastOverlay(toasts)
                // NOT `.preferredColorScheme` — see `fwbAppearanceOverride()`.
                // The override is applied to the window so it reaches sheets
                // that are already open, and so "System" actually reverts.
                .fwbAppearanceOverride()
                .fullScreenCover(isPresented: .constant(isPresentingOnboarding)) {
                    OnboardingGateView()
                        .environment(auth)
                        .environment(onboarding)
                        .environment(toasts)
                }
                .task {
                    await AuthService.shared.restoreSession()

                    // **Launch prefetch — owner directive 2026-08-11: a member
                    // never sees a tab load.** Every tab's data is fetched here,
                    // in parallel and without being awaited, so the first tap on
                    // any of the four shows content instead of a spinner.
                    //
                    // It sits AFTER `restoreSession()` and not in `RootTabView`'s
                    // `.task` on purpose: the two `.task`s start together, so a
                    // prefetch from the shell would race the restore and every
                    // store would ask the signed-out route for a signed-in
                    // member. `AppPrefetch` documents the rest.
                    AppPrefetch.warmAll()

                    // Ask for notification authorization only once there's a
                    // session — a permission prompt on first launch, before the
                    // member knows what the app is, is the reliable way to get
                    // it denied forever.
                    if AuthService.shared.isSignedIn {
                        PushCoordinator.shared.requestAuthorizationAndRegister()
                    }
                    PushCoordinator.shared.drain(appState: appState)
                }
                // Returning to the foreground: refresh every store SILENTLY, and
                // no more than once a minute. Stale content updates underneath
                // the member — nothing moves that they did not cause.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { AppPrefetch.applicationDidBecomeActive() }
                }
                .onChange(of: auth.isSignedIn) { _, signedIn in
                    if signedIn { PushCoordinator.shared.requestAuthorizationAndRegister() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .fwbPushPending)) { _ in
                    PushCoordinator.shared.drain(appState: appState)
                }
        }
    }
}
