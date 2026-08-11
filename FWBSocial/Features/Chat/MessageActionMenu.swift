import SwiftUI

// MARK: - Message action menu
//
// Ported from Cove's `MessageActionMenu` (339 LoC — report 02: "cleanly reusable").
// A sheet rather than a `.contextMenu` for the same reason Cove used one: the
// reaction strip needs to sit above the actions, and a context menu cannot hold an
// interactive row.
//
// Delete is sender-only and is a HARD delete server-side, so it really does remove
// the message for everyone who has not already received it. What it cannot do is
// reach a copy that already decrypted on someone else's phone — §4.7 is explicit —
// and the confirmation copy says that rather than implying a reach the crypto does
// not have.
//
// There is no Edit row: fwb-server has no route for it (see
// `ChatFeatureFlags.editMessage`). The absence is a server gap, not a decision made
// here.

struct MessageActionMenu: View {
    let message: ChatMessage
    let isMine: Bool
    let onReply: () -> Void
    let onReact: (String) -> Void
    let onDelete: () -> Void
    let onReport: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingDelete = false

    private static let quickReactions = ["❤️", "👍", "😂", "😮", "😢", "🙏"]

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            reactionStrip

            VStack(spacing: 0) {
                if ChatFeatureFlags.replyQuoting {
                    actionRow("Reply", systemImage: "arrowshape.turn.up.left") {
                        onReply()
                        dismiss()
                    }
                    Divider().padding(.leading, 52)
                }

                if let text = message.decryptedText, !text.isEmpty {
                    actionRow("Copy", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = text
                        dismiss()
                    }
                }

                if isMine, ChatFeatureFlags.deleteForEveryone {
                    Divider().padding(.leading, 52)
                    actionRow("Delete", systemImage: "trash", role: .destructive) {
                        isConfirmingDelete = true
                    }
                } else if !isMine {
                    Divider().padding(.leading, 52)
                    actionRow("Report", systemImage: "flag", role: .destructive) {
                        onReport()
                        dismiss()
                    }
                }
            }
            .background(Theme.Colors.surface, in: Theme.roundedRect(Theme.Radius.card))
        }
        .padding(Theme.Spacing.lg)
        .presentationDragIndicator(.visible)
        .confirmationDialog(
            "Delete this message?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                onDelete()
                dismiss()
            }
        } message: {
            // The honest sentence. The server can stop serving it; it cannot reach
            // into a copy that already decrypted on someone else's phone.
            Text("This removes it from the server. Anyone who already received it may still have it on their device.")
        }
    }

    /// The reaction this member has already left on the message, if any.
    ///
    /// Read straight off the message's own reaction map — the server sends the full
    /// `emoji → user ids` summary with every message, so there is nothing to fetch.
    private var myReaction: String? {
        guard let me = AuthService.shared.user.flatMap({ UUID(uuidString: $0.id) }) else { return nil }
        return message.reactions.first { $0.value.contains(me) }?.key
    }

    private var reactionStrip: some View {
        HStack(spacing: Theme.Spacing.md) {
            ForEach(Self.quickReactions, id: \.self) { emoji in
                Button {
                    onReact(emoji)
                    dismiss()
                } label: {
                    Text(emoji).font(.title2)
                }
                .accessibilityIdentifier("chat.react.\(emoji)")
                // A button whose label is a bare emoji is announced with the Unicode
                // name of the character ("folded hands", "face with open mouth") and
                // no verb, so six of them in a row read as an unexplained list rather
                // than as six ways to react. The selected trait is what tells a member
                // which one they already left — the strip shows no visual state at all.
                .accessibilityLabel("React with \(ChatReactionLabels.name(for: emoji))")
                .accessibilityAddTraits(myReaction == emoji ? .isSelected : [])
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .frame(maxWidth: .infinity)
        .background(Theme.Colors.surface, in: Capsule())
    }

    private func actionRow(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: systemImage)
                    .frame(width: 24)
                Text(title)
                Spacer()
            }
            .font(Theme.Typography.body)
            .foregroundStyle(role == .destructive ? Theme.Colors.danger : Color.primary)
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Spoken names for reaction emoji
//
// VoiceOver falls back to the Unicode name of a character, which describes the glyph
// rather than the gesture ("face with tears of joy" for a laugh). These are the names
// the strip and the bubble's reaction chips both speak, so the same emoji is never
// called two different things in two places.

nonisolated enum ChatReactionLabels {
    private static let names: [String: String] = [
        "❤️": "heart",
        "👍": "thumbs up",
        "😂": "laugh",
        "😮": "surprise",
        "😢": "sad",
        "🙏": "thanks"
    ]

    /// Falls back to the emoji itself for anything outside the quick strip — a
    /// reaction can arrive from another client with any character at all, and the
    /// system's own pronunciation beats saying nothing.
    static func name(for emoji: String) -> String { names[emoji] ?? emoji }
}
