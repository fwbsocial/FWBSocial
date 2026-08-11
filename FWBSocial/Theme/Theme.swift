// Theme.swift
// FWBSocial
//
// ─────────────────────────────────────────────────────────────────────────────
// FWB SOCIAL DESIGN SYSTEM — single source of truth for the app's visual identity.
//
// PLACEHOLDER BRAND VALUES. Taxonomy (nested-enum shape: Colors / Spacing /
// Typography / Radius / Motion) is ported from Cove's `Theme.swift`
// (Commune/Commune/Views/Theme.swift, READ-ONLY reference — PLAN.md §5's
// "NEW Theme.swift" directive), but every hex value below is a stand-in. Swap
// them for FWB's real brand palette before any real screens ship; the shape
// should not need to change.
//
// `GroupedBubbleShape` is ported verbatim — chat (PLAN.md §4.3) needs it
// unchanged, and it has no brand-specific values to swap.
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI
import UIKit

// MARK: - Theme namespace

enum Theme {

    // MARK: Brand color seeds
    //
    // Jade greens derived from the app icon's pine-green background
    // (ClubhouseBack.png, dominant #204038, hue ~165°) — owner directive
    // 2026-08-10. The flat accent lives in the AccentColor asset so it can
    // adapt per appearance (light #25735F, dark #3E9A72 — greener, deeper than the first mint pass per owner feedback) and stays in sync
    // with the system tint; deep/light bracket the same hue for gradients.
    nonisolated enum Brand {
        /// Flat accent — used for tints, links, toggles. Adaptive via asset.
        static let base  = Color("AccentColor")
        /// Gradient start / pressed state.
        static let deep  = Color(hex: 0x1B584A)
        /// Gradient end / highlights.
        static let light = Color(hex: 0x4FAE85)
    }

    // MARK: Semantic color tokens

    nonisolated enum Colors {
        static let brand = Brand.base
        static let brandDeep = Brand.deep

        /// Hero brand gradient — primary CTAs, sent chat bubbles.
        static let brandGradient = LinearGradient(
            colors: [Brand.deep, Brand.light],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        /// A soft, low-alpha brand wash for fills (avatar rings, chips).
        static let brandSoft = Brand.base.opacity(0.14)

        /// Foreground for anything drawn ON `brand` — primary button titles, sent
        /// bubble text, the unread capsule's number.
        ///
        /// **Not `Color.white`.** The accent is adaptive by design (light `#25735F`,
        /// dark `#56BFA5`), so a fixed white foreground tracks only one of them:
        /// against the dark-mode mint it measures ≈2.1:1, well under WCAG AA's 4.5,
        /// and it was doing that on every sent chat bubble and every primary CTA in
        /// the app. Flipping to a near-black in dark restores ≈9:1 without touching
        /// the accent, which the icon derives from.
        static let onBrand = Color(uiColor: UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.043, green: 0.114, blue: 0.094, alpha: 1)  // #0B1D18
                : UIColor.white
        })

        // — Bubbles (chat, PLAN.md §4.3) —
        static let bubbleSent = Brand.base
        static let bubbleSentText = onBrand
        static let bubbleReceivedText = Color.primary

        // — Theme-dependent surfaces —
        //
        // These five resolve through the member's APP THEME (Standard / Pine /
        // Clubhouse — see AppTheme.swift), which is why they are `var`s that read
        // a palette rather than the `let` constants the rest of this enum is.
        //
        // `AppearanceService` is `@Observable`, so touching `appTheme` here
        // registers a dependency on behalf of whatever view body is evaluating —
        // switching the theme re-renders exactly the views that use a themed
        // token, and nothing else. That is the whole mechanism; no screen reads
        // the theme itself.
        //
        // `@MainActor` (against the enum's `nonisolated` default) because they now
        // touch main-actor state. Every call site is a SwiftUI view body, which is
        // already there.
        @MainActor static var palette: AppTheme.Palette { AppearanceService.shared.appTheme.palette }

        @MainActor static var background: Color { palette.background }
        @MainActor static var surface: Color { palette.surface }
        @MainActor static var field: Color { palette.field }
        @MainActor static var hairline: Color { palette.hairline }
        @MainActor static var bubbleReceived: Color { palette.bubbleReceived }

        // — Status —
        static let positive = Color.green
        static let caution = Color.orange
        static let danger = Color.red
    }

    // MARK: Type scale

    nonisolated enum Typography {
        static let display = Font.system(.largeTitle, design: .rounded).weight(.bold)
        static let title = Font.system(.title2, design: .rounded).weight(.semibold)
        static let rowTitle = Font.system(.body, design: .rounded).weight(.semibold)
        static let headline = Font.system(.headline, design: .rounded)
        static let body = Font.body
        static let preview = Font.subheadline
        static let caption = Font.caption
        static let micro = Font.caption2
        static let badge = Font.system(.caption2, design: .rounded).weight(.bold)

        // MARK: Sue Ellen Francisco — expressive display type
        //
        // Owner directive 2026-08-10. Mirrors the shape Cove uses for Quicksand: a
        // nested enum of a few named roles, every one built with `relativeTo:` so it
        // scales with Dynamic Type rather than freezing at one size.
        //
        // **STYLED ELEMENTS ONLY** — large navigation titles, the welcome wordmark,
        // empty-state headlines, section eyebrows. Body and UI text stay system.
        // This face is a display face: it runs tall and narrow, it has one weight,
        // and it is not legible at caption sizes or in a paragraph.
        //
        // Sizes are ~35 % above the system role they replace, which is what makes
        // the narrow face read at the same optical weight rather than looking
        // shrunken next to system text:
        //
        //     largeTitle 34 → 46      title2 22 → 30
        //     headline   17 → 23      caption 12 → 16
        //
        // The family name in the file is `Sue Ellen Francisco` **with a trailing
        // space**; the PostScript name is `SueEllenFrancisco`. Always the latter —
        // `Font.custom` with a name it cannot resolve falls back to the system face
        // silently, so the trailing space would look like "the directive was
        // ignored" rather than like a bug.
        nonisolated enum Sue {
            static let name = "SueEllenFrancisco"

            private static func make(_ style: Font.TextStyle, size: CGFloat) -> Font {
                Font.custom(name, size: size, relativeTo: style)
            }

            /// The welcome wordmark — sign-in and onboarding only.
            static let hero = make(.largeTitle, size: 46)
            /// A large navigation title.
            static let navTitle = make(.largeTitle, size: 46)
            /// An empty-state headline, or a screen's section heading.
            static let heading = make(.title2, size: 30)
            /// An inline title / small heading.
            static let label = make(.headline, size: 23)
            /// A section eyebrow — the tracked, uppercased kicker above a title.
            static let eyebrow = make(.caption, size: 16)
        }
    }

    // MARK: Spacing scale (4-pt base)

    nonisolated enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 28
    }

    // MARK: Corner radii (all consumed via `.continuous` shapes)

    nonisolated enum Radius {
        static let tight: CGFloat = 6
        static let chip: CGFloat = 10
        static let control: CGFloat = 14
        static let bubble: CGFloat = 20
        static let card: CGFloat = 18
        static let pill: CGFloat = 999
    }

    // MARK: Animation

    nonisolated enum Motion {
        static let bubble = Animation.spring(response: 0.34, dampingFraction: 0.74)
        static let delivery = Animation.spring(response: 0.30, dampingFraction: 0.68)
        static let chrome = Animation.easeInOut(duration: 0.22)
    }
}

// MARK: - Continuous-corner shape helper

extension Theme {
    /// Continuous (super-elliptical) rounded rect — the house corner. Typed as
    /// `some InsettableShape` (not just `Shape`) so call sites can chain
    /// `.strokeBorder(...)` directly, which Cove's own `roundedRect` (typed
    /// `some Shape`, used only via `clipShape`) doesn't need but this kit's
    /// card/button overlays do.
    static func roundedRect(_ radius: CGFloat) -> some InsettableShape {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

extension View {
    /// Clip to a continuous-corner rounded rect.
    func fwbCorner(_ radius: CGFloat) -> some View {
        clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - Grouped-bubble corner shape (ported verbatim from Cove)
//
// A rounded rect where each corner can be either the full bubble radius or a
// tight radius, so consecutive messages from one sender read as a single stack
// with only the group's outer edges fully rounded.

struct GroupedBubbleShape: Shape {
    var topLeading: CGFloat
    var topTrailing: CGFloat
    var bottomLeading: CGFloat
    var bottomTrailing: CGFloat

    init(top: CGFloat, bottom: CGFloat, isFromMe: Bool) {
        // On the sender's side the "spine" is the trailing edge; on the
        // receiver's side it's the leading edge. The spine corners use the
        // grouped (top/bottom) radius; the outer column stays fully round.
        let outer = Theme.Radius.bubble
        if isFromMe {
            topLeading = outer
            bottomLeading = outer
            topTrailing = top
            bottomTrailing = bottom
        } else {
            topTrailing = outer
            bottomTrailing = outer
            topLeading = top
            bottomLeading = bottom
        }
    }

    func path(in rect: CGRect) -> Path {
        Path(
            UnevenRoundedRectangle(
                cornerRadii: .init(
                    topLeading: topLeading,
                    bottomLeading: bottomLeading,
                    bottomTrailing: bottomTrailing,
                    topTrailing: topTrailing
                ),
                style: .continuous
            ).path(in: rect).cgPath
        )
    }
}

// MARK: - Color(hex:) initializer

extension UIColor {
    /// Build a UIColor from a 0xRRGGBB integer literal. The UIKit twin of
    /// `Color(hex:)`, needed because a dynamic (per-appearance) colour can only
    /// be built through `UIColor`'s trait-collection provider.
    nonisolated convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha)
    }
}

extension Color {
    /// Build a Color from a 0xRRGGBB integer literal.
    nonisolated init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
