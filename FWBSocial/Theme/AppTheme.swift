// AppTheme.swift
// FWBSocial
//
// ─────────────────────────────────────────────────────────────────────────────
// APP THEME — what the app is PAINTED ON, as opposed to light/dark, which is
// what the system paints everything on.
//
// Owner exploration 2026-08-11. Three choices:
//
//   Clubhouse  the icon's painted clubhouse texture as a fixed full-bleed photo.
//              THE DEFAULT — owner directive 2026-08-11. See `AppearanceService`.
//   Pine       the icon's pine green as the app's own flat surface.
//   Standard   the system's own backgrounds — grouped grey, white cards.
//
// # Why this is a token, not a set of screens
//
// Every theme-dependent colour is resolved through `Theme.Colors`, which reads
// `AppearanceService.shared.appTheme` — an `@Observable` property, so SwiftUI
// re-renders exactly the views that touched a token when the choice changes. No
// screen knows a theme exists. The only two places that DO know are
// `fwbAppThemeSurface()`, which paints the backdrop, and the picker in Settings.
//
// # Theme and appearance compose — all six combinations are real
//
// Owner directive: neither custom theme forces an interface style. The theme
// picks the FAMILY of colour; light/dark picks where in that family it sits.
//
//   Pine · dark    the icon's background — #162B25–#204038, surfaces lifted out of it
//   Pine · light   the same hue at daylight — a pale sage/mist ramp, pine hairlines
//   Clubhouse      one painting, two scrims: white-leaning in light, black in dark
//
// Every themed token is therefore built with a UIColor dynamic provider, which
// re-resolves on the trait change the window override causes. That is what keeps
// `Color.primary` correct without a single foreground override anywhere: in light
// Pine the ground is pale and the system's near-black label is right; in dark Pine
// the ground is near-black green and the system's near-white label is right.
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI
import UIKit

enum AppTheme: String, CaseIterable, Identifiable {
    // Declaration order is picker order — the default first. The raw values are
    // strings, so this ordering carries no persistence meaning and a stored
    // choice survives it.
    case clubhouse, pine, standard

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard:  return "Standard"
        case .pine:      return "Pine"
        case .clubhouse: return "Clubhouse"
        }
    }

    /// One line in the picker's footer, saying what the member gets. Each one
    /// names BOTH appearances, because the theme choice and the appearance
    /// choice above it compose rather than override.
    var blurb: String {
        switch self {
        case .standard:
            return "The system's own light and dark backgrounds."
        case .pine:
            return "The icon's pine green throughout — deep and near-black in dark, a pale sage at daylight in light."
        case .clubhouse:
            return "The clubhouse painting behind everything, under a scrim that lightens or darkens to keep text readable in either appearance."
        }
    }

    /// Whether the theme draws its own backdrop, which is also the signal to
    /// stop lists and forms painting the system's opaque background over it.
    var paintsOwnBackdrop: Bool { self != .standard }

    // MARK: - Palette

    /// The theme-dependent half of `Theme.Colors`. Everything else — brand,
    /// status, on-brand foregrounds — is theme-independent and stays where it is.
    struct Palette {
        /// The flat background colour behind a screen's content.
        var background: Color
        /// A card / raised row, one step off the background.
        var surface: Color
        /// A text field or other sunken control.
        var field: Color
        /// A separator.
        var hairline: Color
        /// An incoming chat bubble.
        var bubbleReceived: Color
    }

    var palette: Palette {
        switch self {
        case .standard:
            return Palette(
                background: Color(uiColor: .systemBackground),
                surface: Color(uiColor: .secondarySystemBackground),
                field: Color(uiColor: UIColor { tc in
                    tc.userInterfaceStyle == .dark
                        ? UIColor(white: 0.17, alpha: 1)
                        : UIColor(white: 0.95, alpha: 1)
                }),
                hairline: Color.primary.opacity(0.08),
                bubbleReceived: Color(uiColor: UIColor { tc in
                    tc.userInterfaceStyle == .dark
                        ? UIColor(white: 0.23, alpha: 1)
                        : UIColor(white: 0.91, alpha: 1)
                }))

        case .pine:
            // Opaque, and deliberately so. Pine is a surface, not a wash — a
            // translucent card over the pine ramp would pick up the ramp's own
            // gradient and stop reading as a card at the top of a long scroll.
            //
            // "Lifted" inverts with the appearance, because it means "a step
            // towards the light source", not "lighter": in dark that is a paler
            // green than the ground, in light a whiter one.
            return Palette(
                background: Pine.base,
                surface: Pine.lifted,
                field: Pine.sunken,
                // A white hairline over dark pine at the system's 0.08 is very
                // nearly invisible; in light the separator is the pine hue
                // itself, which keeps the theme's colour in the fine detail
                // rather than dropping to a neutral grey.
                hairline: Pine.hairline,
                bubbleReceived: Pine.bubble)

        case .clubhouse:
            // Translucent, because the point is the painting behind them. The
            // wash direction flips with the appearance: lightening in light,
            // darkening in dark, so a card is always a step TOWARDS the text
            // colour's opposite.
            return Palette(
                background: .clear,
                surface: Color(uiColor: UIColor { tc in
                    tc.userInterfaceStyle == .dark
                        ? UIColor(white: 0, alpha: 0.34)
                        : UIColor(white: 1, alpha: 0.62)
                }),
                field: Color(uiColor: UIColor { tc in
                    tc.userInterfaceStyle == .dark
                        ? UIColor(white: 0, alpha: 0.26)
                        : UIColor(white: 1, alpha: 0.50)
                }),
                hairline: Color.primary.opacity(0.14),
                bubbleReceived: Color(uiColor: UIColor { tc in
                    tc.userInterfaceStyle == .dark
                        ? UIColor(white: 0, alpha: 0.42)
                        : UIColor(white: 1, alpha: 0.74)
                }))
        }
    }

    /// Pine's two ramps — one hue, two times of day.
    ///
    /// Dark is the owner's #1A332C–#204038 bracket, straight off the icon's
    /// background. Light is the same hue taken up to daylight: a pale sage/mist
    /// that keeps enough saturation to read as green rather than as grey, and
    /// stays bright enough for the system's near-black label to sit on it. Every
    /// value is a dynamic pair, so a window-level appearance change re-resolves
    /// them with no view doing anything.
    enum Pine {
        /// Top of the ramp.
        static let deep    = adaptive(light: 0xCFE4D8, dark: 0x162B25)
        /// The flat background, and the middle of the ramp.
        static let base    = adaptive(light: 0xBFDACB, dark: 0x1A332C)
        /// Bottom of the ramp.
        static let raised  = adaptive(light: 0xAFCFBE, dark: 0x204038)
        /// A card or row, lifted off the ground.
        static let lifted  = adaptive(light: 0xFAFCFB, dark: 0x24463C)
        /// A field, sunk into it.
        static let sunken  = adaptive(light: 0xA9CCBA, dark: 0x142822)
        /// An incoming bubble.
        static let bubble  = adaptive(light: 0xB3D2C2, dark: 0x2B5147)
        /// A separator: the pine hue in light, a plain white lift in dark.
        static let hairline = Color(uiColor: UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: 0.13)
                : UIColor(red: 0.106, green: 0.345, blue: 0.290, alpha: 0.18)  // #1B584A
        })
    }

    /// A light/dark pair of `0xRRGGBB` literals as one dynamic colour. Resolved
    /// per trait collection, which is what makes a theme's tokens follow the
    /// appearance without the theme knowing what the appearance is.
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { tc in
            UIColor(hex: tc.userInterfaceStyle == .dark ? dark : light)
        })
    }

    // MARK: - Backdrop

    /// The fixed layer painted behind everything. Fixed is the operative word for
    /// Clubhouse: the painting does not scroll with the content, so the content
    /// reads as moving over a room rather than over a very long poster.
    @ViewBuilder
    var backdrop: some View {
        switch self {
        case .standard:
            Color(uiColor: .systemBackground)

        case .pine:
            // The stops are dynamic colours, so this one gradient is both the
            // near-black bracket in dark and the sage-to-mist wash in light.
            LinearGradient(
                colors: [Pine.deep, Pine.base, Pine.raised],
                startPoint: .top,
                endPoint: .bottom)

        case .clubhouse:
            ClubhouseBackdrop()
        }
    }
}

// MARK: - Clubhouse backdrop
//
// The painting, plus the scrim that makes text legible over it.
//
// The painting is a dark mottled pine texture — beautiful, and far too busy and
// too dark to put `Color.primary` on directly in light appearance. The scrim is
// two parts: a flat wash that sets the overall level, and a soft vertical
// gradient that darkens (or, in light, brightens) the top and bottom, where the
// navigation bar's large title and the tab bar's labels sit over it.

private struct ClubhouseBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        // `Color.clear` is what claims the space. A resizable image at
        // `.fill` only reports a size derived from what it is offered, and
        // offered a ZStack's unconstrained proposal it lays out at nothing and
        // draws nothing — which is exactly how this first shipped: a blank
        // white screen indistinguishable from Standard. Filling a `Color.clear`
        // that took the full proposal, then clipping, is the reliable
        // full-bleed form.
        Color.clear
            .overlay {
                Image("ClubhouseBackdrop")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
            .clipped()
            .overlay {
                // Flat wash. Light mode's lift is BAKED INTO the asset now (a
                // brightened variant of the painting), so the runtime scrim only
                // trims the last stop of contrast instead of erasing the art —
                // the 0.74 veil made light Clubhouse indistinguishable from a
                // flat tint (owner feedback 2026-08-11).
                (isDark ? Color.black : Color.white)
                    .opacity(isDark ? 0.42 : 0.20)
            }
            .overlay {
                LinearGradient(
                    colors: isDark
                        ? [.black.opacity(0.34), .black.opacity(0.06), .black.opacity(0.40)]
                        : [.white.opacity(0.26), .white.opacity(0.02), .white.opacity(0.28)],
                    startPoint: .top,
                    endPoint: .bottom)
            }
    }
}

// MARK: - Root surface modifier

private struct AppThemeSurface: ViewModifier {
    @State private var appearance = AppearanceService.shared

    func body(content: Content) -> some View {
        let theme = appearance.appTheme
        content
            // Lists and forms paint an opaque `systemGroupedBackground` of their
            // own, which covers a backdrop completely. This does NOT cross a
            // `NavigationStack` boundary — applied outside one, the Settings form
            // stayed opaque and the backdrop showed only in the strip above it —
            // which is why the modifier goes on the content INSIDE each stack.
            .scrollContentBackground(theme.paintsOwnBackdrop ? .hidden : .automatic)
            // `.background` rather than wrapping in a `ZStack`: it leaves layout
            // untouched, and `.navigationTitle` / `.toolbar` declared by the
            // wrapped screen keep reaching the stack above it.
            .background {
                theme.backdrop.ignoresSafeArea()
            }
    }
}

private struct AppThemeRows: ViewModifier {
    @State private var appearance = AppearanceService.shared

    func body(content: Content) -> some View {
        content
            .listRowBackground(appearance.appTheme.paintsOwnBackdrop ? Theme.Colors.surface : nil)
    }
}

extension View {
    /// Gives list/form rows the app theme's surface colour instead of the
    /// system's opaque grouped background.
    ///
    /// Must be applied to content INSIDE the `List`/`Form` — a row background is
    /// a per-row trait, and setting it on the container from outside does not
    /// reach the rows. Wrapping the sections in a `Group` and applying it there
    /// is one line per screen. Rows that declare their own
    /// `.listRowBackground(.clear)` are closer to the row and still win, which is
    /// what the custom-drawn rows want.
    ///
    /// `nil` on Standard restores the system background rather than pinning it,
    /// so Standard is genuinely untouched.
    func fwbThemedRows() -> some View {
        modifier(AppThemeRows())
    }

    /// Paints the chosen app theme's backdrop behind this content and lets
    /// scrolling content sit on it.
    ///
    /// Applied to the CONTENT OF a `NavigationStack`, never around one — see the
    /// note on `scrollContentBackground` above. In practice that means the four
    /// tab roots in `RootTabView` and the corner-chrome sheet wrapper, all of
    /// which are shell infrastructure; no feature screen applies this.
    func fwbAppThemeSurface() -> some View {
        modifier(AppThemeSurface())
    }
}
