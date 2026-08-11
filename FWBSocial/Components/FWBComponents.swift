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
                    .font(Theme.Typography.Sue.eyebrow)
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(Theme.Typography.Sue.navTitle)
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
///
/// The app's canonical CONTAINER, and the reason `fwbThemedContainer()` is a
/// modifier rather than something each screen remembers: every card in the app
/// goes through here, so light Clubhouse's white-box-with-dark-text is one line
/// in one file. Applied last, wrapping the fill and the contents together — see
/// the modifier's own note on why it cannot go on `content` alone.
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
            .fwbThemedContainer()
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
                .font(Theme.Typography.Sue.heading)
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
        // One identifier for every designed empty state, so a test can assert
        // that a member never SAW one — the prefetch rule's failure mode is an
        // empty state that flashes for a moment and is then replaced by content
        // (owner directive 2026-08-11). `ErrorStateView` re-labels its own copy
        // `error.state` from outside, which still wins.
        .accessibilityIdentifier("empty.state")
    }
}

// MARK: - Avatar

/// Decoded avatars, keyed on the R2 **object path** rather than the whole URL.
///
/// That distinction is the entire point. Avatars are served as presigned R2 URLs
/// with a one-hour expiry, and the server re-mints the signature on every `/me`,
/// every feed page and every profile read — so the same photo arrives as a
/// *different URL string* several times a minute. `AsyncImage` keys on the URL
/// and `FWBHTTP` runs with no `URLCache` (deliberately — bug 8CC9EC4F), so each
/// re-mint was a fresh download that dropped back to the initials placeholder
/// while it ran. The member sees their own face blink into a grey monogram every
/// time a screen refreshes.
///
/// Stripping the query leaves `…/avatars/<user>-<uuid>.jpg`, which is stable for
/// as long as the object is. An upload writes a NEW key (the server deletes the
/// old object), so a changed avatar misses this cache and loads immediately —
/// which is why no cache-busting parameter is needed anywhere.
@MainActor
final class AvatarImageCache {
    static let shared = AvatarImageCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 200
    }

    /// The cache key: everything before the query. Nil for a URL we can't parse,
    /// which simply means "don't cache this one".
    nonisolated static func key(for urlString: String) -> String? {
        guard var components = URLComponents(string: urlString) else { return nil }
        components.query = nil
        components.fragment = nil
        return components.string
    }

    func image(forKey key: String) -> UIImage? { cache.object(forKey: key as NSString) }

    func store(_ image: UIImage, forKey key: String) { cache.setObject(image, forKey: key as NSString) }

    /// Called on every auth transition, alongside `FWBHTTP.clearSharedCache()`.
    /// One member's face must not survive into another member's session.
    func clear() { cache.removeAllObjects() }
}

/// A circular avatar with initials fallback.
struct AvatarView: View {
    let name: String
    var url: String?
    var size: CGFloat = 40

    @State private var loaded: UIImage?

    var body: some View {
        Group {
            if let loaded {
                Image(uiImage: loaded).resizable().scaledToFill()
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Theme.Colors.hairline, lineWidth: 1))
        // `id:` on the URL, so a member who changes their photo — or a row that
        // is recycled onto a different person — reloads instead of keeping the
        // previous face.
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url, let parsed = URL(string: url) else {
            loaded = nil
            return
        }
        let key = AvatarImageCache.key(for: url)
        if let key, let cached = AvatarImageCache.shared.image(forKey: key) {
            loaded = cached
            return
        }
        // Only blank the previous image when there is nothing cached to show —
        // otherwise a re-mint of the same object would flash the monogram, which
        // is the whole thing this cache exists to prevent.
        loaded = nil
        guard let (data, response) = try? await FWBHTTP.session.data(from: parsed),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let image = UIImage(data: data)
        else { return }
        if let key { AvatarImageCache.shared.store(image, forKey: key) }
        loaded = image
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
        // A field is furniture. It also carries the keyboard's appearance and the
        // placeholder's colour, both of which come off `\.colorScheme` — a field
        // left on the canvas in light Clubhouse would be a white box with a white
        // placeholder in it and a dark keyboard under it.
        .fwbThemedContainer()
    }
}

// MARK: - Button styles

struct FWBPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.headline)
            // Adaptive, not `.white` — see `Theme.Colors.onBrand`. This one style
            // backs every primary CTA in the app, so the dark-mode contrast failure
            // it carried was app-wide.
            .foregroundStyle(Theme.Colors.onBrand)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.Colors.brand.opacity(isEnabled ? 1 : 0.4), in: Theme.roundedRect(Theme.Radius.control))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            // Both the accent and `onBrand` are adaptive, and they are a matched
            // PAIR — the light accent is measured against white, the dark accent
            // against near-black. Restoring the real appearance keeps them
            // together; leaving the button on the canvas would take the dark half
            // of one and, on an empty state's CTA, sit it next to light copy.
            .fwbThemedContainer()
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
            // `.primary` on `Theme.Colors.field` — the one combination that is
            // white-on-white the moment the fill flips and the label does not.
            .fwbThemedContainer()
    }
}
