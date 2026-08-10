import SwiftUI

@main
struct FWBSocialApp: App {
    @UIApplicationDelegateAdaptor(FWBAppDelegate.self) private var appDelegate

    @State private var appState = AppState.shared
    @State private var appearance = AppearanceService.shared
    @State private var toasts = ToastCenter()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(appState)
                .environment(appearance)
                .environment(toasts)
                .fwbToastOverlay(toasts)
                .preferredColorScheme(appearance.theme.colorScheme)
                .task {
                    await AuthService.shared.restoreSession()
                    PushCoordinator.shared.drain(appState: appState)
                }
                .onReceive(NotificationCenter.default.publisher(for: .fwbPushPending)) { _ in
                    PushCoordinator.shared.drain(appState: appState)
                }
        }
    }
}
