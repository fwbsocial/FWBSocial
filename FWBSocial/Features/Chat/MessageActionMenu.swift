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
