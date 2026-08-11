// AppTheme.swift
// FWBSocial
//
// ─────────────────────────────────────────────────────────────────────────────
// APP THEME — what the app is PAINTED ON, as opposed to light/dark, which is
// what the system paints everything on.
//
// Owner exploration 2026-08-11. Three choices:
//
//   Standard   the system's own backgrounds — grouped grey, white cards. Default.
//   Pine       the icon's deep pine green as the app's own surface.
//   Clubhouse  the icon's painted clubhouse texture as a fixed full-bleed photo.
//
// # Why this is a token, not a set of screens
//
// Every theme-dependent colour is resolved through `Theme.Colors`, which reads
// `AppearanceService.shared.appTheme` — an `@Observable` property, so SwiftUI
// re-renders exactly the views that touched a token when the choice changes. No
// screen knows a theme exists. The only two places that DO know are
// `fwbAppThemeSurface()`, which paints the backdrop, and the picker in Settings.
//
// # Why Pine forces dark
//
// Pine's palette is a dark palette — it is the icon's background, and the icon's
// background is nearly black-green. Rendered under a LIGHT interface style,
// `Color.primary` resolves to near-black and every label on the app goes
// unreadable against it. Forcing the window to `.dark` is what makes "ensure
// text/hairline/bubble tokens all read correctly" true for free: the semantic
// colours the whole app already uses resolve to their dark values, which are the
// correct ones over a dark surface. The alternative — a parallel light-pine
// palette plus per-view foreground overrides — is the per-view hack this file
// exists to avoid.
//
// Clubhouse does NOT force a style: its scrim is appearance-aware (a white wash
// in light, a black one in dark), so the same photo carries both.
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI
import UIKit

enum AppTheme: String, CaseIterable, Identifiable {
    case standard, pine, clubhouse

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard:  return "Standard"
        case .pine:      return "Pine"
        case .clubhouse: return "Clubhouse"
        }
    }

    /// One line in the picker's footer. Says what the member gets, including the
    /// part that surprises them — that Pine ignores the appearance setting above it.
    var blurb: String {
        switch self {
        case .standard:  return "The system's own light and dark backgrounds."
        case .pine:      return "The icon's deep pine green, throughout. Pine is a dark theme, so it stays dark whatever the appearance above is set to."
        case .clubhouse: return "The clubhouse painting behind everything, dimmed enough to read over in either appearance."
        }
    }

    /// A style this theme insists on, overriding the member's light/dark choice.
    /// Only Pine has one — see the file comment.
    var forcedInterfaceStyle: UIUserInterfaceStyle? {
        switch self {
        case .pine: return .dark
        case .standard, .clubhouse: return nil
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
            return Palette(
                background: Pine.base,
                surface: Pine.lifted,
                field: Pine.sunken,
                // 0.08 white over pine is very nearly invisible; the separator
                // has to survive a dark, low-contrast ground.
                hairline: Color.white.opacity(0.13),
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

    /// Pine's ramp. Owner's values: a #1A332C–#204038 bracket, with surfaces
    /// lifted off it rather than outlined.
    enum Pine {
        static let dark   = Color(hex: 0x162B25)
        static let base   = Color(hex: 0x1A332C)
        static let raised = Color(hex: 0x204038)
        static let lifted = Color(hex: 0x24463C)
        static let sunken = Color(hex: 0x142822)
        static let bubble = Color(hex: 0x2B5147)
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
            LinearGradient(
                colors: [Pine.dark, Pine.base, Pine.raised],
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
                // Flat wash. Light needs much more of it: the source is a dark
                // painting, and dark text on it is unreadable at any smaller value.
                (isDark ? Color.black : Color.white)
                    .opacity(isDark ? 0.42 : 0.74)
            }
            .overlay {
                LinearGradient(
                    colors: isDark
                        ? [.black.opacity(0.34), .black.opacity(0.06), .black.opacity(0.40)]
                        : [.white.opacity(0.42), .white.opacity(0.04), .white.opacity(0.46)],
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
