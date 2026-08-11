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
//   Clubhouse      ONE canvas in both appearances; the furniture on it flips
//
// Every themed token is therefore built with a UIColor dynamic provider, which
// re-resolves on the trait change the window override causes. That is what keeps
// `Color.primary` correct without a single foreground override anywhere: in light
// Pine the ground is pale and the system's near-black label is right; in dark Pine
// the ground is near-black green and the system's near-white label is right.
//
// # Clubhouse: the canvas is constant, the furniture flips
//
// OWNER REDESIGN 2026-08-11. The first light Clubhouse washed the painting out
// with a white scrim until it read as flat grey, and that is rejected. The rule
// now is:
//
//   • The BACKDROP is the same dark watercolour in both appearances. Light gets a
//     ~1.15 brightness lift baked into the asset — no white blend, no
//     desaturation — and essentially no runtime wash on top of it.
//   • Text sitting DIRECTLY ON that canvas — large navigation titles, the
//     wordmark, empty and error states, section headers, captions outside a card —
//     is light in BOTH appearances.
//   • The FURNITURE — cards, list rows, fields, bubbles, buttons — flips with the
//     appearance: near-opaque white with dark text in light, dark translucent in
//     dark.
//
// That is implemented as an INVERTED-CONTAINER pattern rather than as a pile of
// per-view foreground overrides:
//
//   1. `fwbAppThemeSurface()` (the root of every surface) forces
//      `\.colorScheme == .dark` for its content under Clubhouse, so `.primary`,
//      `.secondary` and every system semantic resolve light on the canvas, and it
//      hands the bars the same style with `.toolbarColorScheme(.dark, …)`.
//   2. Before doing that it republishes the REAL appearance — whatever the window
//      override left in `\.colorScheme` — as `\.fwbContainerScheme`.
//   3. `fwbThemedContainer()` reads that back and restores it locally, so a card's
//      interior renders with the member's actual appearance and stock system
//      semantics. In light Clubhouse that is dark-on-white; in dark it is a no-op.
//
// Two properties make this safe. It is a pure ENVIRONMENT operation, so it
// composes with `UIWindow.overrideUserInterfaceStyle` (`AppearanceService`) rather
// than fighting it — the window still decides what "the real appearance" IS, and
// this only decides who gets to see it. And `\.fwbContainerScheme` is nil under
// Standard and Pine, which makes `fwbThemedContainer()` a literal no-op there:
// neither of those themes changes by a pixel.
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
            return "The clubhouse painting behind everything, in both appearances — light only lifts it. Cards, rows and fields turn white in light and dark in dark."
        }
    }

    /// Whether the theme draws its own backdrop, which is also the signal to
    /// stop lists and forms painting the system's opaque background over it.
    var paintsOwnBackdrop: Bool { self != .standard }

    /// Whether content sitting directly on this theme's backdrop should be drawn
    /// in a forced DARK context regardless of the member's appearance — the
    /// inverted-container pattern described at the top of this file.
    ///
    /// True for Clubhouse alone, because Clubhouse alone has a canvas that stays
    /// dark in both appearances. Pine's ground genuinely inverts (near-black green
    /// ↔ pale sage) and Standard is the system's own, so for both of those the
    /// stock semantics are already right and this must stay false.
    var invertsOnCanvasContent: Bool { self == .clubhouse }

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
            // THE FURNITURE, and the only half of Clubhouse that flips.
            //
            // In DARK these stay translucent, because the point is the painting
            // showing through them. In LIGHT they are near-opaque WHITE boxes
            // sitting on the same dark painting — owner directive 2026-08-11,
            // "the boxes being white instead of black looks great". They are not
            // fully opaque only so the canvas still grains through at the edges;
            // at these alphas nothing of the painting's own contrast reaches the
            // text inside.
            //
            // These values are read INSIDE `fwbThemedContainer()`, which restores
            // the member's real appearance, so the `.light` branch is what a light
            // member sees and `Color.primary` inside the box is the system's
            // near-black against it.
            return Palette(
                background: .clear,
                surface: Color(uiColor: UIColor { tc in
                    tc.userInterfaceStyle == .dark
                        ? UIColor(white: 0, alpha: 0.34)
                        : UIColor(white: 1, alpha: 0.96)
                }),
                // A shade off white rather than white: a field inside a white card
                // has only its hairline to distinguish it otherwise, and a sunken
                // control that reads as a gap in the card is not a control.
                field: Color(uiColor: UIColor { tc in
                    tc.userInterfaceStyle == .dark
                        ? UIColor(white: 0, alpha: 0.26)
                        : UIColor(white: 0.93, alpha: 0.97)
                }),
                hairline: Color.primary.opacity(0.14),
                bubbleReceived: Color(uiColor: UIColor { tc in
                    tc.userInterfaceStyle == .dark
                        ? UIColor(white: 0, alpha: 0.42)
                        : UIColor(white: 1, alpha: 0.95)
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
// THE CANVAS. One painting, drawn the same way in both appearances.
//
// The asset carries two variants of the SAME dark mottled pine watercolour:
// the original for dark, and — for light — the identical crop with a ~1.15
// brightness multiply baked in (`ClubhouseBackdropLight@2x/@3x.jpg`, rebaked from
// `ClubhouseTallHK.PNG` 2026-08-11). A multiply, deliberately: it lifts the level
// without touching saturation, where the previous pass blended white into it and
// left a flat grey that the owner rejected. Measured, the rebake holds the dark
// original's saturation to three decimal places.
//
// Nothing else lightens it. There is no white wash and no white edge gradient,
// because the text that goes over the top and bottom of this canvas — the large
// navigation title, the tab labels — is light in BOTH appearances now (see the
// inverted-container note at the top of the file), so both edges want DARKENING,
// exactly as dark mode always did. Light's alphas are lower only because it is
// starting from a brighter plate.
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
                // Flat wash — DARKENING in both, and in light barely there at all.
                // Dark's 0.42 is what settles the painting behind a dark
                // translucent card. Light's 0.03 is a hair off nothing: the lift
                // it needs is already baked into the asset, and anything above
                // ~0.04 starts erasing the art again, which is the exact failure
                // this redesign replaces.
                Color.black.opacity(isDark ? 0.42 : 0.03)
            }
            .overlay {
                // Edge gradient — also DARKENING in both. The top carries the
                // large title, the bottom carries the tab labels, and both are
                // light text in either appearance, so both edges need to go down,
                // never up. Light runs at roughly two thirds of dark's alpha
                // because the plate underneath it is already brighter.
                LinearGradient(
                    colors: isDark
                        ? [.black.opacity(0.34), .black.opacity(0.06), .black.opacity(0.40)]
                        : [.black.opacity(0.24), .black.opacity(0.04), .black.opacity(0.28)],
                    startPoint: .top,
                    endPoint: .bottom)
            }
    }
}

// MARK: - The canvas / container seam
//
// One environment value carries the whole inverted-container pattern.

private struct FWBContainerSchemeKey: EnvironmentKey {
    static let defaultValue: ColorScheme? = nil
}

private struct FWBWindowSchemeKey: EnvironmentKey {
    static let defaultValue: ColorScheme? = nil
}

extension EnvironmentValues {
    /// The member's actual Light / Dark / System choice, resolved, published once
    /// at the app root by `fwbAppearanceOverride()` straight from
    /// `AppearanceService.resolvedAppearance`.
    ///
    /// **Not** read from `\.colorScheme`, and this is the crux of the whole
    /// mechanism. Under Clubhouse the WINDOW is held at dark whatever the member
    /// picked (`AppearanceService.windowStyle` — that is what makes the UIKit
    /// chrome sit correctly on the canvas), so `\.colorScheme` says "dark"
    /// everywhere and has nothing left to say about the appearance. This value is
    /// the only surviving statement of what the member actually chose, and it is
    /// what every container flips on.
    var fwbWindowScheme: ColorScheme? {
        get { self[FWBWindowSchemeKey.self] }
        set { self[FWBWindowSchemeKey.self] = newValue }
    }

    /// The appearance the WINDOW is actually in, republished by
    /// `fwbAppThemeSurface()` at the moment it forces a dark context for
    /// on-canvas content — and read back by `fwbThemedContainer()` to restore it
    /// inside a card.
    ///
    /// `nil` means no inversion is in effect (Standard, Pine, and anything drawn
    /// outside a themed surface), which is what makes `fwbThemedContainer()` a
    /// no-op rather than a second opinion about the appearance.
    var fwbContainerScheme: ColorScheme? {
        get { self[FWBContainerSchemeKey.self] }
        set { self[FWBContainerSchemeKey.self] = newValue }
    }
}

/// Restores the member's real appearance inside a container.
///
/// Deliberately branch-free: `?? inherited` collapses to "write back what is
/// already there" when no inversion is in effect, rather than an `if/else` that
/// would give the wrapped content two different view identities depending on the
/// theme (house gotcha — an `if/else` wrapper splits identity, and a card that
/// changes identity on a theme switch loses its state and its animation).
private struct AppThemeContainer: ViewModifier {
    @Environment(\.fwbContainerScheme) private var containerScheme
    @Environment(\.colorScheme) private var inherited

    func body(content: Content) -> some View {
        content
            .environment(\.colorScheme, containerScheme ?? inherited)
    }
}

/// The other direction: puts content back ON the canvas after something above it
/// restored the real appearance.
///
/// Needed in exactly one shape, and it is a real one — a `Form`'s section HEADERS
/// and FOOTERS. `fwbThemedRows()` has to wrap whole `Section`s, because a row
/// background is a per-row trait that only reaches the rows if it is set on
/// something inside the list; but a header is not in a row, it sits on the
/// backdrop between two white boxes, and the restore would hand it the system's
/// dark secondary label there. This pins those few labels back to the canvas.
private struct AppThemeOnCanvas: ViewModifier {
    @Environment(\.fwbContainerScheme) private var containerScheme
    @Environment(\.colorScheme) private var inherited

    func body(content: Content) -> some View {
        // A non-nil container scheme is the signal that an inversion is in effect
        // at all — and whenever one is, the canvas is dark by definition.
        content
            .environment(\.colorScheme, containerScheme == nil ? inherited : .dark)
    }
}

// MARK: - Root surface modifier

private struct AppThemeSurface: ViewModifier {
    @State private var appearance = AppearanceService.shared
    /// What arrives in `\.colorScheme` — normally the member's Light / Dark /
    /// System choice, already resolved by the window override this modifier sits
    /// below.
    @Environment(\.colorScheme) private var inheritedScheme
    /// The truth, published at the app root. See `windowScheme`.
    @Environment(\.fwbWindowScheme) private var rootScheme
    /// The truth as republished by an OUTER themed surface — the fallback for a
    /// presentation that somehow arrived without the root value.
    @Environment(\.fwbContainerScheme) private var inheritedReal

    /// The real appearance, whatever the route here was.
    ///
    /// `\.colorScheme` alone is wrong here in two different ways, and both were
    /// observed. A SwiftUI sheet inherits its presenter's environment, so the two
    /// corner-chrome sheets — presented from a root surface that has already
    /// forced dark — read `.dark` and faithfully re-inverted an inversion: for a
    /// LIGHT member, Settings and Profile came up with every card black and the
    /// backdrop on the unlifted plate. And under Clubhouse `BarStyleBridge` pushes
    /// a dark trait onto the enclosing navigation controller, which lands in
    /// `\.colorScheme` for the whole stack. Both are this modifier's own output
    /// coming back around; the root value never is.
    private var windowScheme: ColorScheme { rootScheme ?? inheritedReal ?? inheritedScheme }

    func body(content: Content) -> some View {
        let theme = appearance.appTheme
        let inverts = theme.invertsOnCanvasContent
        let canvasScheme: ColorScheme = inverts ? .dark : windowScheme

        content
            // A surface must CLAIM the whole screen before the backdrop paints:
            // `.background` sizes to the modified view, and a screen whose root
            // is an intrinsically-sized view (Chat's empty state) otherwise gets
            // a BAND of painting over black — owner screenshot 2026-08-11.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Lists and forms paint an opaque `systemGroupedBackground` of their
            // own, which covers a backdrop completely. This does NOT cross a
            // `NavigationStack` boundary — applied outside one, the Settings form
            // stayed opaque and the backdrop showed only in the strip above it —
            // which is why the modifier goes on the content INSIDE each stack.
            .scrollContentBackground(theme.paintsOwnBackdrop ? .hidden : .automatic)
            // Hand the containers the real appearance BEFORE overriding it, then
            // override it. Order matters only in that both writes have to be
            // inside the same subtree as the content; they are.
            .environment(\.fwbContainerScheme, inverts ? windowScheme : nil)
            .environment(\.colorScheme, canvasScheme)
            // `.background` rather than wrapping in a `ZStack`: it leaves layout
            // untouched, and `.navigationTitle` / `.toolbar` declared by the
            // wrapped screen keep reaching the stack above it.
            //
            // The backdrop is pinned to the WINDOW's appearance, not the canvas's.
            // It is the one thing that must not be inverted: `ClubhouseBackdrop`
            // picks its asset variant off `\.colorScheme`, and forcing dark here
            // would hand a light member the unlifted plate.
            .background {
                theme.backdrop
                    .environment(\.colorScheme, windowScheme)
                    .ignoresSafeArea()
            }
    }
}

private struct AppThemeRows: ViewModifier {
    @State private var appearance = AppearanceService.shared
    @Environment(\.fwbContainerScheme) private var containerScheme
    @Environment(\.colorScheme) private var inherited

    func body(content: Content) -> some View {
        // A row IS a container: in light Clubhouse it is a white box and its
        // contents have to be dark against it.
        let scheme = containerScheme ?? inherited
        return content
            .listRowBackground(
                // Handed over RESOLVED — a flat colour for one appearance, not a
                // dynamic one and not a view carrying its own environment. Two
                // separate failures got it here, both observed:
                //
                //  * A bare `Theme.Colors.surface` is rendered by the LIST, in the
                //    list's environment, which the `.fwbThemedContainer()` below
                //    does not reach. It resolved against the canvas: Channels came
                //    up dark-translucent boxes with dark text in them.
                //  * Wrapping it in `.environment(\.colorScheme, scheme)` fixed
                //    that but only while something else was also forcing a redraw.
                //    Under Clubhouse with the appearance on **System**, the window
                //    is pinned dark either way, so an OS light->dark switch changes
                //    no trait at all — the row CONTENTS re-rendered from the
                //    environment and the row BACKGROUND kept its old view. White
                //    boxes, white text.
                //
                // A resolved colour is a different VALUE when the appearance
                // changes, which is the one thing the list is guaranteed to notice.
                appearance.appTheme.paintsOwnBackdrop
                    ? Color(uiColor: UIColor(Theme.Colors.surface).resolvedColor(
                        with: UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)))
                    : nil)
            // The contents. Applied outside the row background so the two agree.
            //
            // This also reaches section headers and footers, which are NOT in a
            // row and do not want it — see `fwbOnCanvas()`, which the two Form
            // screens put on theirs.
            .fwbThemedContainer()
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
    ///
    /// Under Clubhouse this is also where the inverted-container pattern starts:
    /// everything below it is drawn as if the appearance were dark, because
    /// everything below it is sitting on a dark painting. See the top of this file.
    func fwbAppThemeSurface() -> some View {
        modifier(AppThemeSurface())
    }

    /// Marks this view as a CONTAINER — a card, a row, a field, a bubble, a
    /// button — and restores the member's real appearance inside it.
    ///
    /// Apply it to the WHOLE composed container, background and contents
    /// together, never to the contents alone: the surface colour and the text on
    /// it have to be resolved in the same appearance or the box is white with
    /// white text in it. In practice that means it goes last, after
    /// `.background(…)` and any `.overlay(…)` border.
    ///
    /// A no-op unless a themed surface above it declared an inversion, which
    /// only Clubhouse does — Standard and Pine are untouched by design.
    func fwbThemedContainer() -> some View {
        modifier(AppThemeContainer())
    }

    /// The inverse: keeps this view on the CANVAS's appearance even though
    /// something above it restored the real one.
    ///
    /// One use, and a real one — a `Form`'s section headers and footers, which
    /// `fwbThemedRows()` unavoidably wraps along with the rows but which sit on
    /// the backdrop rather than in a white box. See `AppThemeOnCanvas`.
    func fwbOnCanvas() -> some View {
        modifier(AppThemeOnCanvas())
    }
}
