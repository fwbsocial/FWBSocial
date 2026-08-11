import SwiftUI

// MARK: - Generic component kit
//
// Ported from Flux's `Components/FluxComponents.swift` (PLAN.md §5.2), adapted
// to reference the static `Theme` namespace directly (Theme.swift's Cove-style
// nested enums) instead of Flux's `@Environment(\.fluxTheme)` resolver — this
// app has one fixed theme, not a pluggable design-lab. `StatusBadge`'s
// Flux-specific `init(status: GuestStatus)` convenience is dropped; every other
// shape ports as-is.

// MARK: - Section header

struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var eyebrow: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let eyebrow {
                Text(eyebrow.uppercased())
                    .font(Theme.Typography.caption.weight(.medium))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(Theme.Typography.display)
                .foregroundStyle(.primary)
            if let subtitle {
                Text(subtitle)
                    .font(Theme.Typography.preview)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Card container

/// A rounded surface card with hairline border.
struct FWBCard<Content: View>: View {
    var padding: CGFloat = Theme.Spacing.lg
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.surface, in: Theme.roundedRect(Theme.Radius.card))
            .overlay(
                Theme.roundedRect(Theme.Radius.card)
                    .strokeBorder(Theme.Colors.hairline, lineWidth: 1))
    }
}

// MARK: - Status badge / pill

/// A small colored status pill.
struct StatusBadge: View {
    let text: String
    var color: Color = Theme.Colors.brand

    init(_ text: String, color: Color = Theme.Colors.brand) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(Theme.Typography.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    let icon: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(Theme.Typography.title)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(Theme.Typography.preview)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(FWBPrimaryButtonStyle())
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Avatar

/// A circular avatar with initials fallback.
struct AvatarView: View {
    let name: String
    var url: String?
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let url, let u = URL(string: url) {
                AsyncImage(url: u) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    default: initials
                    }
                }
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Theme.Colors.hairline, lineWidth: 1))
    }

    private var initials: some View {
        ZStack {
            Theme.Colors.brandSoft
            Text(initialsText)
                .font(.system(size: size * 0.4, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.Colors.brand)
        }
    }

    private var initialsText: String {
        let parts = name.split(separator: " ").prefix(2)
        let chars = parts.compactMap { $0.first }
        return chars.isEmpty ? "?" : String(chars).uppercased()
    }
}

// MARK: - Keyboard dismissal
//
// House convention: tap-outside-to-dismiss on every text field. The trap it
// avoids is specific — attaching `.onTapGesture` to a `Form` kills every row
// control in it (rows stop responding to taps entirely), and
// `.simultaneousGesture` doesn't fix it either. The working shape is a
// *background layer* behind the content, which is what this does.

/// Resign the first responder, wherever it is.
///
/// Worth calling as the first thing a form's submit does: without it the
/// keyboard survives the navigation that follows and sits over the top of the
/// next screen, covering its controls.
@MainActor
func fwbDismissKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder),
        to: nil, from: nil, for: nil)
}

extension View {
    /// Dismiss the keyboard when the user taps outside a field.
    ///
    /// Safe on scroll views and stacks. **Do not reach for `.onTapGesture` on a
    /// `Form`** — use this, which puts the tap target behind the content
    /// instead of in front of it.
    func fwbDismissKeyboardOnTap() -> some View {
        background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { fwbDismissKeyboard() }
        )
    }
}

// MARK: - Inline form error

/// A single-line validation/error message under a field or form.
struct FormErrorText: View {
    let message: String?

    var body: some View {
        if let message, !message.isEmpty {
            Label(message, systemImage: "exclamationmark.circle.fill")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
        }
    }
}

// MARK: - Styled text field

/// The auth-screen field: themed background, no capitalisation surprises.
struct FWBTextField: View {
    let title: String
    @Binding var text: String
    var systemImage: String?
    var contentType: UITextContentType?
    var keyboard: UIKeyboardType = .default
    var isSecure: Bool = false
    var submitLabel: SubmitLabel = .next
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }
            Group {
                if isSecure {
                    SecureField(title, text: $text)
                } else {
                    TextField(title, text: $text)
                }
            }
            .textInputAutocapitalization(contentType == .name ? .words : .never)
            .autocorrectionDisabled()
            .textContentType(contentType)
            .keyboardType(keyboard)
            .submitLabel(submitLabel)
            .onSubmit(onSubmit)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, 14)
        .background(Theme.Colors.field, in: Theme.roundedRect(Theme.Radius.control))
        .overlay(
            Theme.roundedRect(Theme.Radius.control)
                .strokeBorder(Theme.Colors.hairline, lineWidth: 1))
    }
}

// MARK: - Button styles

struct FWBPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.Colors.brand.opacity(isEnabled ? 1 : 0.4), in: Theme.roundedRect(Theme.Radius.control))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
    }
}

struct FWBSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.headline)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.Colors.field, in: Theme.roundedRect(Theme.Radius.control))
            .overlay(Theme.roundedRect(Theme.Radius.control).strokeBorder(Theme.Colors.hairline, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
