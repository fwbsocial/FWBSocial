import SwiftUI

// MARK: - Message bubble
//
// Ported from Cove's `MessageBubble` (ChatView 1793–2435, ~640 LoC — report 02:
// "cleanly reusable, reads `message.decryptedText` only"). That property is the
// whole reason it ports cleanly: the bubble knows nothing about wrapped keys,
// quantum policy or device sets, and this port keeps it that way.
//
// The one thing it DOES know about encryption is the placeholder. A message with no
// plaintext has two very different causes, and conflating them is how a working
// feature reads as broken:
//
//   • no wrapped key for this device — "Sent before this device was added". Normal,
//     documented (PLAN.md §4.3.3(B)), and repaired by A2's handoff.
//   • a key that failed to open — an actual decryption failure.

struct MessageBubble: View {
    let message: ChatMessage
    let isMine: Bool
    let senderName: String?
    let isGroup: Bool
    let groupsWithPrevious: Bool
    let groupsWithNext: Bool
    let replyPreview: String?
    let onTap: () -> Void
    let onRetry: () -> Void

    @State private var mediaImage: UIImage?
    @State private var mediaError = false

    var body: some View {
        HStack {
            if isMine { Spacer(minLength: 60) }

            VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
                if isGroup, !isMine, !groupsWithPrevious, let senderName {
                    Text(senderName)
                        .font(Theme.Typography.micro.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, Theme.Spacing.md)
                }

                bubble

                if !message.reactions.isEmpty {
                    reactionRow
                }

                if !groupsWithNext {
                    footer
                }
            }

            if !isMine { Spacer(minLength: 60) }
        }
        .padding(.vertical, groupsWithNext ? 1 : 3)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    // MARK: Bubble

    private var bubble: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if let replyPreview {
                HStack(spacing: 6) {
                    Rectangle()
                        .fill(isMine ? Color.white.opacity(0.6) : Theme.Colors.brand)
                        .frame(width: 2)
                    Text(replyPreview)
                        .font(Theme.Typography.micro)
                        .lineLimit(2)
                        .opacity(0.85)
                }
            }

            if message.contentType == .image {
                mediaContent
            }

            if let text = message.decryptedText, !text.isEmpty {
                Text(text)
                    .font(Theme.Typography.body)
                    .textSelection(.enabled)
            } else if message.contentType == .text || message.decryptedText == nil {
                Label(message.placeholderText, systemImage: message.hasKeyForThisDevice ? "exclamationmark.triangle" : "clock.badge.questionmark")
                    .font(Theme.Typography.preview.italic())
                    .opacity(0.75)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .foregroundStyle(isMine ? Theme.Colors.bubbleSentText : Theme.Colors.bubbleReceivedText)
        .background(isMine ? AnyShapeStyle(Theme.Colors.bubbleSent) : AnyShapeStyle(Theme.Colors.bubbleReceived))
        .clipShape(GroupedBubbleShape(
            top: groupsWithPrevious ? Theme.Radius.tight : Theme.Radius.bubble,
            bottom: groupsWithNext ? Theme.Radius.tight : Theme.Radius.bubble,
            isFromMe: isMine
        ))
        .opacity(message.sendState == .pending ? 0.65 : 1)
    }

    /// The decrypt seam Cove used, unchanged: the R2 object is ciphertext and the
    /// content key is the same one that opened the body. `decryptMedia` is where that
    /// happens, and there is nothing to swap out under E2EE — PLAN.md §5.2 keeps both
    /// media files "untouched" for exactly this reason.
    @ViewBuilder
    private var mediaContent: some View {
        if let mediaImage {
            Image(uiImage: mediaImage)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 240, maxHeight: 320)
                .fwbCorner(Theme.Radius.chip)
        } else if mediaError {
            Label("Photo unavailable", systemImage: "photo.badge.exclamationmark")
                .font(Theme.Typography.caption)
        } else {
            ProgressView()
                .frame(width: 160, height: 160)
                .task {
                    do {
                        let data = try await ChatService.shared.decryptMedia(for: message)
                        mediaImage = UIImage(data: data)
                        mediaError = mediaImage == nil
                    } catch {
                        mediaError = true
                    }
                }
        }
    }

    // MARK: Reactions

    private var reactionRow: some View {
        HStack(spacing: 4) {
            ForEach(message.reactions.sorted(by: { $0.key < $1.key }), id: \.key) { emoji, users in
                HStack(spacing: 2) {
                    Text(emoji)
                    if users.count > 1 {
                        Text("\(users.count)")
                            .font(Theme.Typography.micro)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.Colors.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.Colors.hairline))
            }
        }
        .font(Theme.Typography.caption)
        .padding(.horizontal, Theme.Spacing.xs)
    }

    // MARK: Footer — time, receipts, send state

    private var footer: some View {
        HStack(spacing: 4) {
            if message.sendState == .failed {
                Button(action: onRetry) {
                    Label("Not delivered · Tap to retry", systemImage: "arrow.clockwise")
                        .font(Theme.Typography.micro)
                        .foregroundStyle(Theme.Colors.danger)
                }
            } else {
                Text(message.createdAt, format: .dateTime.hour().minute())
                    .font(Theme.Typography.micro)
                    .foregroundStyle(.tertiary)

                if message.editedAt != nil {
                    Text("edited")
                        .font(Theme.Typography.micro)
                        .foregroundStyle(.tertiary)
                }

                if isMine {
                    receiptGlyph
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.xs)
    }

    /// Read beats delivered beats sent. The counts come from the server's recipient
    /// rows — the client has no independent view of another member's devices, so
    /// there is nothing to compute here, only to render.
    @ViewBuilder
    private var receiptGlyph: some View {
        switch message.sendState {
        case .pending:
            Image(systemName: "clock").font(Theme.Typography.micro).foregroundStyle(.tertiary)
        case .failed:
            EmptyView()
        case .sent:
            if message.readCount > 0 {
                Image(systemName: "checkmark.circle.fill")
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.Colors.brand)
            } else if message.deliveredCount > 0 {
                Image(systemName: "checkmark.circle")
                    .font(Theme.Typography.micro)
                    .foregroundStyle(.tertiary)
            } else {
                Image(systemName: "checkmark")
                    .font(Theme.Typography.micro)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Typing bubble

struct TypingBubble: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0 ..< 3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 5, height: 5)
                    .opacity(phase == index ? 1 : 0.35)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.Colors.bubbleReceived, in: Capsule())
        .task {
            // No `autoreverses` — house preference
            // (`feedback_ambient_animation_no_autoreverse`): a reversing dot loop
            // reads as a stutter rather than a march.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(320))
                withAnimation(.easeInOut(duration: 0.2)) { phase = (phase + 1) % 3 }
            }
        }
    }
}
