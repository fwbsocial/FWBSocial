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
}
