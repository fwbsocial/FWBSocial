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

// MARK: - Theme namespace

enum Theme {

    // MARK: Brand color seeds (PLACEHOLDER)
    //
    // A warm coral→amber pair — a stand-in "social, warm, in-person" identity,
    // distinct from Cove's cool violet (chat is a DIFFERENT product surface
    // here, not the whole app — PLAN.md §0's two-content-surfaces split).
    nonisolated enum Brand {
        /// Flat accent — used for tints, links, toggles.
        static let base  = Color(hex: 0xFF5A5F)
        /// Gradient start / pressed state.
        static let deep  = Color(hex: 0xD1373C)
        /// Gradient end / highlights.
        static let light = Color(hex: 0xFF8A65)
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

        // — Bubbles (chat, PLAN.md §4.3) —
        static let bubbleSent = Brand.base
        static let bubbleReceived = Color(uiColor: UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(white: 0.23, alpha: 1)
                : UIColor(white: 0.91, alpha: 1)
        })
        static let bubbleSentText = Color.white
        static let bubbleReceivedText = Color.primary

        // — Surfaces —
        static let background = Color(uiColor: .systemBackground)
        static let surface = Color(uiColor: .secondarySystemBackground)
        static let field = Color(uiColor: UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(white: 0.17, alpha: 1.0)
                : UIColor(white: 0.95, alpha: 1.0)
        })
        static let hairline = Color.primary.opacity(0.08)

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

extension Color {
    /// Build a Color from a 0xRRGGBB integer literal.
    nonisolated init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
