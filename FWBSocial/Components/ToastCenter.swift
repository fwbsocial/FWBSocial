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
            Image(systemName: icon).foregroundStyle(color)
            Text(message.text)
                .font(Theme.Typography.body.weight(.medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.Colors.surface, in: Theme.roundedRect(14))
        .overlay(Theme.roundedRect(14).strokeBorder(Theme.Colors.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 16)
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
