import SwiftUI
import UIKit
import OSLog

private let logger = Logger(subsystem: "events.fwb.social", category: "Appearance")

/// User appearance preferences (color scheme + home-screen icon), persisted in
/// `UserDefaults`. House convention: every app ships light/dark/system
/// appearance + an app-icon picker (`feedback_settings_appearance_icon_picker_convention`
/// memory) — pattern copied from Flux's `Services/AppearanceService.swift`.
///
/// `IconPreference` has exactly one case for now: FWBSocial.icon (PLAN.md
/// addendum A1) composes its light AND dark renders into a single Icon
/// Composer document, so iOS switches automatically with system appearance —
/// there is no separate "dark" *alternate* icon to pick the way Flux has
/// `FluxIconDark`. The picker still exists (structurally ready for a future
/// alternate) so Settings matches the fleet shape.
@Observable
@MainActor
final class AppearanceService {

    static let shared = AppearanceService()

    // MARK: - Theme

    enum Theme: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light:  return .light
            case .dark:   return .dark
            }
        }
    }

    // MARK: - Icon

    enum IconPreference: String, CaseIterable, Identifiable {
        case standard
        var id: String { rawValue }
        var label: String { "Default" }
        /// Asset-catalog alternate icon name; `nil` = the primary AppIcon.
        var alternateIconName: String? { nil }
    }

    // MARK: - Storage

    private let themeKey = "FWBSocial.appearance.theme"
    private let iconKey  = "FWBSocial.appearance.iconPreference"

    var theme: Theme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: themeKey) }
    }

    private(set) var iconPreference: IconPreference
    var lastIconError: String?

    private init() {
        theme = UserDefaults.standard.string(forKey: themeKey).flatMap(Theme.init(rawValue:)) ?? .system
        iconPreference = UserDefaults.standard.string(forKey: iconKey).flatMap(IconPreference.init(rawValue:)) ?? .standard
    }

    // MARK: - Icon switching

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
}
