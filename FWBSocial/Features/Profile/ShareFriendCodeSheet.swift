import SwiftUI

// MARK: - Share your friend code
//
// The Feed's contextual action for everyone who is not an admin (owner directive
// 2026-08-11: the trailing slot is never empty on a page a member can act on).
//
// # Why this action, on this screen
//
// Commissioner decision 9 removes member search from fwb social entirely, in v1
// and after. That leaves exactly three ways to reach a person, and the only one a
// member can start themselves is handing out their eight-character code. It has
// lived on the Profile sheet — two taps behind an avatar — and nowhere else. The
// Feed is the screen everyone opens, so it is where the invite belongs.
//
// The code is a **shared secret**, which is why this is a deliberate share rather
// than something printed on every post: `ForumAuthor` carries no `friendCode` for
// exactly that reason.

struct ShareFriendCodeSheet: View {
    /// Optional because `AuthUser.friendCode` is: the column is populated at
    /// registration, but a session restored from an older token can arrive without
    /// it, and an empty screen under a "Friend code" title reads as a bug.
    let code: String?

    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            if let code, !code.isEmpty {
                present(code)
            } else {
                EmptyStateView(
                    icon: "questionmark.circle",
                    title: "No code yet",
                    message: "Your friend code hasn't come through. Pull to refresh the feed, or sign out and back in.")
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(Theme.Spacing.xl)
        .navigationTitle("Friend code")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func present(_ code: String) -> some View {
        Text("There's no member search on fwb social, on purpose. Your code is how someone adds you.")
            .font(Theme.Typography.preview)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)

        Text(code)
            .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
            // Eight characters at largeTitle already fill an iPhone's width, and at
            // accessibility sizes they overflow it — scaling down beats truncating
            // a code that has to be transcribed correctly.
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.lg)
            .background(Theme.Colors.field, in: Theme.roundedRect(Theme.Radius.card))
            .fwbThemedContainer()
            // VoiceOver reads "AB7K2Q41" as a mangled word, which is useless for
            // something being read aloud to another person. Spaced out, it is
            // spelled character by character.
            .accessibilityElement()
            .accessibilityLabel("Your friend code: \(code.map(String.init).joined(separator: " "))")
            .accessibilityIdentifier("friendCode.value")

        VStack(spacing: Theme.Spacing.md) {
            ShareLink(item: "Add me on fwb social — friend code: \(code)") {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(FWBPrimaryButtonStyle())
            // A custom label suppresses ShareLink's own wording, which would
            // otherwise leave VoiceOver with a bare "Share".
            .accessibilityLabel("Share your friend code")
            .accessibilityIdentifier("friendCode.share")

            Button {
                UIPasteboard.general.string = code
                toasts.show("Friend code copied")
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(FWBSecondaryButtonStyle())
            .accessibilityLabel("Copy your friend code")
            .accessibilityIdentifier("friendCode.copy")
        }

        Text("Codes are exact — whoever you send it to types it in, and nobody can guess their way to you.")
            .font(Theme.Typography.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}
