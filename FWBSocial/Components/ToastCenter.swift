import SwiftUI
import Observation

// MARK: - Toast model
//
// Ported from Flux's `Components/Toast.swift` (PLAN.md §5.2), adapted to the
// static `Theme` namespace (see `FWBComponents.swift`'s note).

struct ToastMessage: Identifiable, Equatable {
    enum Kind { case success, error, info }
    let id = UUID()
    let text: String
    let kind: Kind
}

/// A small toast/banner presenter. Inject `ToastCenter` into the environment and
/// call `toasts.show(...)`. Render `.fwbToastOverlay()` once near the root of a
/// screen (or attach to any container).
@Observable
@MainActor
final class ToastCenter {
    private(set) var current: ToastMessage?

    func show(_ text: String, kind: ToastMessage.Kind = .info) {
        let message = ToastMessage(text: text, kind: kind)
        current = message
        // A toast is a plain overlay: it steals no focus and replaces no content, so
        // VoiceOver had no reason to say anything and never did. That silently
        // swallowed every failure routed through `toasts.error(...)` — a member who
        // could not see the banner got no feedback at all that an action had failed.
        // An announcement is the only channel that reaches them, and it has to be
        // posted here rather than in the view: the banner is gone again in 2.6
        // seconds, well before a member could go looking for it.
        AccessibilityNotification.Announcement(text).post()
        Task {
            try? await Task.sleep(for: .seconds(2.6))
            if current?.id == message.id { current = nil }
        }
    }

    func success(_ text: String) { show(text, kind: .success) }
    func error(_ text: String) { show(text, kind: .error) }
}

// MARK: - Banner view

struct ToastBanner: View {
    let message: ToastMessage

    @Environment(\.colorScheme) private var colorScheme

    private var color: Color {
        switch message.kind {
        case .success: return Theme.Colors.positive
        case .error:   return Theme.Colors.danger
        case .info:    return Theme.Colors.brand
        }
    }

    private var icon: String {
        switch message.kind {
        case .success: return "checkmark.circle.fill"
        case .error:   return "exclamationmark.triangle.fill"
        case .info:    return "info.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                // The glyph only restates the kind the sentence already carries.
                .accessibilityHidden(true)
            Text(message.text)
                .font(Theme.Typography.body.weight(.medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.Colors.surface, in: Theme.roundedRect(14))
        // Separation from whatever the banner floats over has to come from somewhere
        // in BOTH appearances. A drop shadow only works against a lighter backdrop —
        // in dark mode the page behind is near-black and a black shadow is simply
        // invisible, leaving the toast's own dark surface bleeding into the screen.
        // There the border carries it instead, so it is drawn brighter.
        .overlay(Theme.roundedRect(14).strokeBorder(
            colorScheme == .dark ? Color.white.opacity(0.16) : Theme.Colors.hairline,
            lineWidth: 1))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.12), radius: 12, y: 4)
        .padding(.horizontal, 16)
        // One element, not two, and static text rather than an unlabelled group: the
        // banner is a statement, and nothing in it is interactive.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - Overlay modifier

private struct ToastOverlayModifier: ViewModifier {
    let center: ToastCenter
    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let message = center.current {
                ToastBanner(message: message)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
            }
        }
        .animation(.spring(duration: 0.3), value: center.current)
    }
}

extension View {
    /// Overlay a toast banner driven by a `ToastCenter`.
    func fwbToastOverlay(_ center: ToastCenter) -> some View {
        modifier(ToastOverlayModifier(center: center))
    }
}
