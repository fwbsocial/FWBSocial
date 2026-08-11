import SwiftUI
import UIKit
import OSLog

private let logger = Logger(subsystem: "events.fwb.social", category: "Appearance")

/// User appearance preferences (color scheme + home-screen icon), persisted in
/// `UserDefaults`. House convention: every app ships light/dark/system
/// appearance + an app-icon picker (`feedback_settings_appearance_icon_picker_convention`
/// memory) — pattern copied from Flux's `Services/AppearanceService.swift`.
///
/// `IconPreference` has two cases. `FWBSocial.icon` composes its light AND dark
/// renders into one Icon Composer document, so "Default" follows the Home
/// Screen's icon appearance on its own. "Dark" is `FWBSocialDark.icon`: the same
/// art, with the dark specializations promoted to the document's BASE appearance
/// and the dark background material authored as an explicit solid fill, because
/// an alternate icon renders its base appearance in light mode — a document that
/// only carries dark *overrides* would show its light default on a light Home
/// Screen, which is the one thing this option exists to prevent.
@Observable
@MainActor
final class AppearanceService {

    static let shared = AppearanceService()

    // MARK: - Theme

    enum Theme: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var label: String { rawValue.capitalized }

        /// The UIKit style this maps to. `.unspecified` — not "no opinion, keep
        /// what you had" — is what makes "System" genuinely revert. See
        /// `applyToWindows()` for why this is the interface rather than
        /// `ColorScheme?`.
        var uiStyle: UIUserInterfaceStyle {
            switch self {
            case .system: return .unspecified
            case .light:  return .light
            case .dark:   return .dark
            }
        }
    }

    // MARK: - Icon

    enum IconPreference: String, CaseIterable, Identifiable {
        /// The primary `FWBSocial.icon` — composes light AND dark renders, so
        /// iOS follows the member's Home Screen icon appearance automatically.
        case standard
        /// `FWBSocialDark.icon` — the same art with the dark specializations
        /// promoted to the base appearance, so it stays dark whatever the Home
        /// Screen is set to.
        case dark

        var id: String { rawValue }

        var label: String {
            switch self {
            case .standard: return "Default"
            case .dark:     return "Dark"
            }
        }

        /// Asset-catalog alternate icon name; `nil` = the primary AppIcon.
        var alternateIconName: String? {
            switch self {
            case .standard: return nil
            case .dark:     return "FWBSocialDark"
            }
        }

        /// Picker thumbnail. These are small PNGs extracted from the COMPILED
        /// `Assets.car` renders of the two `.icon` documents (house method,
        /// `reference_icon_composer_light_dark`) — never hand-drawn, and never the
        /// loose PNGs actool writes next to the car, which are background-only.
        /// `IconPreviewDefault` carries a dark-appearance variant so the Default
        /// cell shows what that icon actually does; `IconPreviewDark` is one image
        /// in both appearances, because that is the whole point of it.
        var previewImage: String {
            switch self {
            case .standard: return "IconPreviewDefault"
            case .dark:     return "IconPreviewDark"
            }
        }
    }

    // MARK: - Storage

    private let themeKey = "FWBSocial.appearance.theme"
    private let iconKey  = "FWBSocial.appearance.iconPreference"
    private let appThemeKey = "FWBSocial.appearance.appTheme"

    var theme: Theme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: themeKey) }
    }

    /// What the app is painted on — Standard / Pine / Clubhouse. See AppTheme.swift.
    var appTheme: AppTheme {
        didSet { UserDefaults.standard.set(appTheme.rawValue, forKey: appThemeKey) }
    }

    private(set) var iconPreference: IconPreference
    var lastIconError: String?

    private init() {
        theme = UserDefaults.standard.string(forKey: themeKey).flatMap(Theme.init(rawValue:)) ?? .system
        appTheme = UserDefaults.standard.string(forKey: appThemeKey).flatMap(AppTheme.init(rawValue:)) ?? .standard
        iconPreference = UserDefaults.standard.string(forKey: iconKey).flatMap(IconPreference.init(rawValue:)) ?? .standard
    }

    // MARK: - Icon switching

    /// Pull the stored preference back in line with the icon iOS is actually
    /// showing. They drift: deleting an alternate from the bundle, or a restore
    /// onto a new device, resets the live icon while `UserDefaults` still claims
    /// the old choice — and a picker with a checkmark on the wrong cell is worse
    /// than one that is merely out of date.
    func reconcileIconPreference() {
        let live = UIApplication.shared.alternateIconName
        guard let match = IconPreference.allCases.first(where: { $0.alternateIconName == live }),
              match != iconPreference else { return }
        iconPreference = match
        UserDefaults.standard.set(match.rawValue, forKey: iconKey)
    }

    func setIconPreference(_ pref: IconPreference) async throws {
        guard UIApplication.shared.supportsAlternateIcons else {
            let msg = "This device doesn't support alternate icons."
            lastIconError = msg
            throw NSError(domain: "FWBSocial.AppearanceService", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        let target = pref.alternateIconName
        if UIApplication.shared.alternateIconName == target {
            iconPreference = pref
            UserDefaults.standard.set(pref.rawValue, forKey: iconKey)
            return
        }
        do {
            try await UIApplication.shared.setAlternateIconName(target)
            iconPreference = pref
            UserDefaults.standard.set(pref.rawValue, forKey: iconKey)
            lastIconError = nil
        } catch {
            lastIconError = error.localizedDescription
            logger.error("Failed to set alternate icon: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Applying the appearance
    //
    // House standard, `feedback_appearance_switch_window_override`: the override
    // goes on the WINDOW, never on a view.
    //
    // `.preferredColorScheme(theme.colorScheme)` at the app root — which is what
    // this app shipped with — has a one-way bug that Bobak has had to have fixed
    // in "just about every app". SwiftUI reads `nil` as "this view expresses no
    // preference", not as "revert to the system", so an ALREADY-PRESENTED sheet
    // keeps whatever explicit scheme it was given. Switching Light → Dark
    // restyles the open Settings sheet; switching Dark → System leaves it dark
    // until it is closed and reopened. The sheet hosting the picker is, of
    // course, the one surface the member is looking at while they use it.
    //
    // `UIWindow.overrideUserInterfaceStyle = .unspecified` genuinely reverts,
    // and it sits above the whole presentation stack — sheets, full-screen
    // covers and alerts are all presented within the same window, so they
    // inherit it live with no per-view plumbing at all.

    /// Push the current theme onto every window in the app.
    ///
    /// `animated` cross-dissolves the change, which is what the system itself
    /// does when the real setting flips; an instant swap of every colour on
    /// screen reads as a glitch.
    func applyToWindows(animated: Bool = false) {
        // The app theme wins where it has an opinion: Pine is a dark palette, and
        // rendering it under a light interface style would put near-black labels
        // on a near-black green. See AppTheme.swift.
        let style = appTheme.forcedInterfaceStyle ?? theme.uiStyle
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where window.overrideUserInterfaceStyle != style {
                guard animated else {
                    window.overrideUserInterfaceStyle = style
                    continue
                }
                UIView.transition(with: window, duration: 0.22, options: .transitionCrossDissolve) {
                    window.overrideUserInterfaceStyle = style
                }
            }
        }
    }
}

// MARK: - Root modifier

private struct AppearanceWindowOverride: ViewModifier {
    @State private var appearance = AppearanceService.shared

    func body(content: Content) -> some View {
        content
            .onAppear { appearance.applyToWindows() }
            .onChange(of: appearance.theme) { _, _ in
                appearance.applyToWindows(animated: true)
            }
            // The app theme can force a style of its own (Pine is dark-only), so
            // changing it has to re-resolve the window override too.
            .onChange(of: appearance.appTheme) { _, _ in
                appearance.applyToWindows(animated: true)
            }
            // Windows are created after this view appears, and go on being
            // created for the app's whole life — an alert or an action sheet
            // brings up its own. Each one arrives at the system style, so
            // without this it would ignore the member's choice.
            .onReceive(NotificationCenter.default.publisher(for: UIWindow.didBecomeVisibleNotification)) { _ in
                appearance.applyToWindows()
            }
    }
}

extension View {
    /// Applies the member's light/dark/system choice at the window level, live,
    /// in both directions, including over already-presented sheets. Attach once,
    /// at the app's root.
    func fwbAppearanceOverride() -> some View {
        modifier(AppearanceWindowOverride())
    }
}
