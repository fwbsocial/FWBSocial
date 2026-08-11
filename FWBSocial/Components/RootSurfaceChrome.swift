import SwiftUI

// MARK: - Root-surface chrome
//
// OWNER NAVIGATION DIRECTIVE 2026-08-10.
//
// The tab bar is four tabs — Home / Channels / Chat / Events — and the two
// surfaces that used to occupy the last two slots move to the corners of every
// root surface:
//
//   top-LEFT   the member's avatar → ProfileView
//   top-RIGHT  a gear → SettingsView
//
// # Why sheets and not pushes
//
// The directive leaves the choice open. Each tab owns its own `NavigationStack`, so
// pushing Profile would put a *copy* of it on four different stacks, each with its
// own back history — and the back button from Profile would say "Channels", which is
// nonsense. Cove's language puts identity and settings in sheets over the current
// surface for exactly this reason: they are modal detours, not destinations within a
// tab. Account deletion stays where it is, inside `ProfileView`, reachable
// unchanged.
//
// # The floating action button
//
// One component, a per-surface action and visibility. Bottom-trailing, above the tab
// bar. Stock `.glass` sizing per fleet convention — the chrome is NOT hand-rolled,
// because a hand-rolled capsule with a blur behind it is exactly what stops looking
// right the moment the system's material changes.
//
// **The glyph colour is deliberately `.primary`, not the brand tint** (house gotcha
// `feedback_swiftui_glass_chrome_adaptive_color`): Liquid Glass adapts its own
// backing to whatever is behind it, and a fixed tint that reads perfectly over a
// light list disappears over a dark photo. `.primary` is the one foreground that
// tracks the material.

// MARK: - Corner chrome

private struct RootSurfaceChrome: ViewModifier {
    @State private var auth = AuthService.shared
    @State private var isPresentingProfile = false
    @State private var isPresentingSettings = false
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        content
            .toolbar {
                // Signed OUT, there is no profile to open — and an avatar drawn
                // from a placeholder name would be inviting a visitor to tap their
                // own face before they have one. Home already carries its own
                // "Sign in" affordance for that case.
                if let user = auth.user {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            isPresentingProfile = true
                        } label: {
                            // The avatar IS the button — the member's own face reads
                            // as "you" far faster than a person glyph does.
                            AvatarView(name: user.displayName, url: user.avatarUrl)
                                .frame(width: 30, height: 30)
                        }
                        .accessibilityLabel("Your profile")
                        .accessibilityIdentifier("chrome.profile")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isPresentingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("chrome.settings")
                }
            }
            .sheet(isPresented: $isPresentingProfile) {
                DismissableSheet { ProfileView() }
            }
            .sheet(isPresented: $isPresentingSettings) {
                DismissableSheet { SettingsView() }
            }
            // A friend-request push has no screen of its own; the friends list lives
            // inside Profile, so the route opens that sheet.
            .onChange(of: appState.isPresentingProfile) { _, wants in
                if wants {
                    isPresentingProfile = true
                    appState.isPresentingProfile = false
                }
            }
    }
}

extension View {
    /// Applies the leading avatar and trailing gear. Every ROOT surface gets this;
    /// pushed detail screens deliberately do not — their corners belong to Back and
    /// to whatever that screen's own actions are.
    func rootSurfaceChrome() -> some View {
        modifier(RootSurfaceChrome())
    }
}

// MARK: - Floating action button

/// The one contextual action for a surface, or nothing.
///
/// Visibility is the caller's decision because it is an authorisation question every
/// time — admin-only on Home, `mayPost` on a channel feed — and a button that
/// appears and then 403s is worse than no button.
struct FloatingActionButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .medium))
                // `.primary`, not the brand tint — see the note above.
                .foregroundStyle(.primary)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.glass)
        .controlSize(.extraLarge)
        .accessibilityLabel(label)
        .accessibilityIdentifier("fab")
        .padding(.trailing, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.lg)
    }
}

extension View {
    /// Overlays the surface's single contextual action, bottom-trailing above the
    /// tab bar. `isVisible: false` renders nothing at all rather than a disabled
    /// button — a greyed-out action still advertises a capability the member does
    /// not have.
    @ViewBuilder
    func floatingAction(
        isVisible: Bool,
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        if isVisible {
            // `.frame(maxHeight: .infinity)` before the overlay is load-bearing: the
            // overlay anchors to THIS view's bounds, and an empty state is only as
            // tall as its content — which put the button mid-screen, on top of the
            // very CTA it duplicates.
            frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottomTrailing) {
                    FloatingActionButton(systemImage: systemImage, label: label, action: action)
                }
        } else {
            self
        }
    }
}

// MARK: - Sheet wrapper with an explicit Done button
//
// Corner-chrome sheets (Profile, Settings) are dismissable by swipe, but an
// explicit Done matters for discoverability, VoiceOver, and Switch Control —
// owner directive 2026-08-11.
struct DismissableSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder var content: Content

    var body: some View {
        NavigationStack {
            content
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                            .fontWeight(.semibold)
                            .accessibilityIdentifier("sheet.done")
                    }
                }
        }
    }
}
