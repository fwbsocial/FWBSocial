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
                    // The avatar IS the chrome (owner directive 2026-08-11): no
                    // glass backing at all — the circle itself is the control,
                    // sized to match the other chrome bubbles. `.circle` border
                    // shape still couldn't stop the backing reading as a pill
                    // (the glass pads horizontally); hiding the shared background
                    // removes the backing rather than fighting its geometry.
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            isPresentingProfile = true
                        } label: {
                            AvatarView(name: user.displayName, url: user.avatarUrl)
                                .frame(width: 44, height: 44)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Your profile")
                        .accessibilityIdentifier("chrome.profile")
                    }
                    .sharedBackgroundVisibility(.hidden)
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

// MARK: - Contextual compose action (trailing tab-bar slot)

extension View {
    /// Registers the surface's single contextual action into the tab bar's
    /// trailing slot — owner directive 2026-08-11: the four tabs stay grouped
    /// left; the trailing slot always holds its space (so tab geometry never
    /// shifts) and carries whatever the current surface needs.
    ///
    /// **Owner directive 2026-08-11 (second pass): every page registers.** The
    /// slot is never left empty on a page a member can act on — Feed shares a
    /// friend code when it has no announcement to write, a comment-only channel
    /// offers its mute toggle rather than a compose button that would 403. The
    /// two remaining `isVisible: false` cases are honest ones: a signed-OUT
    /// visitor (who has no account to act with) and a not-yet-vetted member
    /// (for whom every forum route refuses).
    ///
    /// `isVisible: false` registers nothing — a greyed-out action would still
    /// advertise a capability the member does not have, and visibility is an
    /// authorisation question every time.
    ///
    /// Registration follows the surface's presence AND its content: the glyph,
    /// the label and the handler are all re-registered when any of them change,
    /// which is what lets a toggle (mute / unmute) redraw itself in the slot and
    /// what stops a captured handler going stale against the state it reads.
    ///
    /// - Parameters:
    ///   - label: **One word.** The slot keeps `role: .search` (owner final
    ///     decision 2026-08-11) and a search-role tab is icon-only, so this is
    ///     not drawn today — the glyph and the page carry the meaning on screen.
    ///     It stays short and accurate as the name of the action and as the
    ///     fallback when no `voiceOverLabel` is given.
    ///   - voiceOverLabel: The full phrase, and **the thing anyone actually
    ///     hears**. Always supply one: "Mute" says nothing on its own, where
    ///     "Mute Announcements Discussion" says everything.
    func floatingAction(
        isVisible: Bool,
        systemImage: String,
        label: String,
        voiceOverLabel: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        modifier(ContextualActionRegistrar(
            isVisible: isVisible,
            systemImage: systemImage,
            label: label,
            voiceOverLabel: voiceOverLabel,
            action: action))
    }
}

private struct ContextualActionRegistrar: ViewModifier {
    @Environment(AppState.self) private var appState
    let isVisible: Bool
    let systemImage: String
    let label: String
    let voiceOverLabel: String?
    let action: () -> Void

    /// This registrar's claim on the slot. Stable for the lifetime of the view.
    @State private var owner = UUID()
    /// Whether this surface is the one on screen. A view that has been pushed
    /// over still evaluates its modifiers when its own state changes, and
    /// without this an off-screen list refreshing behind a detail screen would
    /// snatch the slot back from the screen the member is actually looking at.
    @State private var isOnScreen = false

    func body(content: Content) -> some View {
        content
            .onAppear { isOnScreen = true; register() }
            .onDisappear { isOnScreen = false; release() }
            .onChange(of: isVisible) { register() }
            // A toggle changes its own glyph and wording, and re-registering is
            // also what re-captures `action` against current state.
            .onChange(of: systemImage) { register() }
            .onChange(of: label) { register() }
            .onChange(of: voiceOverLabel) { register() }
    }

    private func register() {
        guard isOnScreen else { return }
        guard isVisible else { return release() }
        appState.contextualAction = .init(
            owner: owner,
            systemImage: systemImage,
            label: label,
            voiceOverLabel: voiceOverLabel,
            handler: action)
    }

    /// Only ever clears a registration this registrar can prove is its own.
    private func release() {
        guard appState.contextualAction?.owner == owner else { return }
        appState.contextualAction = nil
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
                // A sheet is its own presentation, so the tab shell's backdrop
                // does not reach it. Themed here rather than at each screen:
                // this wrapper is what Profile and Settings are presented in.
                // INSIDE the stack, because hiding a form's scroll background
                // does not cross that boundary.
                .fwbAppThemeSurface()
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
