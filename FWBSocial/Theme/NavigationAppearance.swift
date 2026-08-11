import SwiftUI
import UIKit

// MARK: - Navigation bar appearance
//
// Owner directive 2026-08-10: large navigation titles use the Sue Ellen Francisco
// display face.
//
// SwiftUI has no modifier for this. `.navigationTitle` renders through
// `UINavigationBar`, and the only way to restyle it is `UINavigationBarAppearance`
// — so this is UIKit by necessity, not by preference, and it is confined to this
// one file rather than leaking `UINavigationBar.appearance()` calls across views.
//
// # Scroll-under headers
//
// The same appearance object carries the Cove idiom the directive asks for: a
// TRANSPARENT scroll-edge appearance, so a large title sits directly on the
// content's background and the bar materialises only once content slides under it.
// `configureWithTransparentBackground` on `scrollEdgeAppearance` plus
// `configureWithDefaultBackground` on `standardAppearance` is exactly that
// transition — the default pairing gives an opaque bar at rest, which reads as a
// hard seam above the first row.
//
// # Why `scaledFont` and not a fixed size
//
// A `UIFont(name:size:)` at a literal size ignores Dynamic Type, so a member who
// has raised their text size gets a title that stays put while every other label
// grows. `UIFontMetrics` scales it against the same text style
// `Theme.Typography.Sue` uses on the SwiftUI side, so the two agree.

enum NavigationAppearance {

    /// Applied once, at launch. Idempotent — re-applying is harmless, and the
    /// appearance proxy is global state, so doing it anywhere else would make the
    /// order it happens in matter.
    static func apply() {
        let standard = UINavigationBarAppearance()
        standard.configureWithDefaultBackground()
        standard.titleTextAttributes = [.font: inlineFont]
        standard.largeTitleTextAttributes = [.font: largeFont]

        let scrollEdge = UINavigationBarAppearance()
        // Transparent at rest: the large title sits on the content's own
        // background and the bar only appears as content scrolls under it.
        scrollEdge.configureWithTransparentBackground()
        scrollEdge.titleTextAttributes = [.font: inlineFont]
        scrollEdge.largeTitleTextAttributes = [.font: largeFont]

        let proxy = UINavigationBar.appearance()
        proxy.standardAppearance = standard
        proxy.compactAppearance = standard
        proxy.scrollEdgeAppearance = scrollEdge
        proxy.compactScrollEdgeAppearance = scrollEdge
    }

    // MARK: - Fonts

    /// 46 pt to match `Theme.Typography.Sue.navTitle` — ~35 % above the system
    /// large title's 34 pt, which is what makes this narrow face read at the same
    /// optical weight rather than looking shrunken.
    private static var largeFont: UIFont {
        scaled(size: 46, textStyle: .largeTitle)
    }

    /// 23 pt, matching `Sue.label` against the system inline title's 17 pt.
    private static var inlineFont: UIFont {
        scaled(size: 23, textStyle: .headline)
    }

    /// The custom face, scaled for Dynamic Type — or the system font if it cannot
    /// be resolved.
    ///
    /// The fallback is deliberate and load-bearing. `UIFont(name:)` returns nil
    /// when the font is not registered (a missing `UIAppFonts` entry, a renamed
    /// file), and force-unwrapping would turn a bundling mistake into a launch
    /// crash. A missing display face should look like a plain title, not like a
    /// broken app.
    private static func scaled(size: CGFloat, textStyle: UIFont.TextStyle) -> UIFont {
        let metrics = UIFontMetrics(forTextStyle: textStyle)
        guard let font = UIFont(name: Theme.Typography.Sue.name, size: size) else {
            return metrics.scaledFont(for: .preferredFont(forTextStyle: textStyle))
        }
        return metrics.scaledFont(for: font)
    }
}
