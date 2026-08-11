import SwiftUI

// MARK: - Message action menu
//
// Ported from Cove's `MessageActionMenu` (339 LoC — report 02: "cleanly reusable").
// A sheet rather than a `.contextMenu` for the same reason Cove used one: the
// reaction strip needs to sit above the actions, and a context menu cannot hold an
// interactive row.
//
// One action is missing on purpose. Cove offered "delete for everyone"; fwb-server's
// `DELETE /api/chat/messages/:id` is sender-only and §4.7 is explicit that the
// server **cannot** remove a message from another participant's device. Offering a
// button that implies otherwise would be a lie the crypto cannot back up, so the
// copy says what actually happens.

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
                actionRow("Reply", systemImage: "arrowshape.turn.up.left") {
                    onReply()
                    dismiss()
                }

                if let text = message.decryptedText, !text.isEmpty {
                    Divider().padding(.leading, 52)
                    actionRow("Copy", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = text
                        dismiss()
                    }
                }

                if isMine {
                    Divider().padding(.leading, 52)
                    actionRow("Delete", systemImage: "trash", role: .destructive) {
                        isConfirmingDelete = true
                    }
                } else {
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
