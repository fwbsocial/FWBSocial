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
    let onOpenMedia: () -> Void
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
        // A photo's tap belongs to the photo — opening an action sheet when someone
        // taps an image is the wrong verb. Long-press reaches the actions from
        // either kind of bubble.
        .onTapGesture { message.contentType == .image ? onOpenMedia() : onTap() }
        .onLongPressGesture(minimumDuration: 0.35, perform: onTap)
        // Both of the above are raw gestures on a plain `Rectangle` content shape, so
        // VoiceOver saw a stack of loose text with no button and no long-press: every
        // chat action — reply, copy, delete, report, and opening a photo — was
        // unreachable. Folding the row into one element with a spoken label puts the
        // tap on the rotor as a button, and the named action gives the long-press a
        // keyboard/rotor equivalent. Nothing here touches the gestures themselves, so
        // the touch behaviour for sighted members is unchanged.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(message.contentType == .image
            ? "Opens the photo full screen."
            : "Opens message actions.")
        .accessibilityActions {
            Button("Message actions", action: onTap)
            // The retry button lives inside the footer, which the combine above
            // absorbs; a failed send is the one thing a member must be able to act on,
            // so it gets its own action rather than relying on that survival.
            if message.sendState == .failed {
                Button("Retry sending", action: onRetry)
            }
        }
    }

    // MARK: Spoken description

    /// The whole row as one sentence.
    ///
    /// Composed by hand rather than left to `children: .combine`, because the two
    /// things carrying the most meaning have no text to harvest: a photo message is an
    /// `Image` with nothing to read, and the sender's name is drawn only on the FIRST
    /// bubble of a run — so someone swiping through a group thread heard a stream of
    /// anonymous sentences. Reactions, time and receipt state are folded in here for
    /// the same reason: this label replaces whatever combine would have built.
    private var spokenLabel: String {
        var parts: [String] = []

        if isMine {
            parts.append("You")
        } else if isGroup, let senderName {
            parts.append(senderName)
        }

        if let replyPreview {
            parts.append("Replying to \(replyPreview)")
        }

        if message.contentType == .image {
            parts.append(mediaError ? "Photo unavailable" : "Photo")
        }

        // Mirrors the bubble's own branch so the spoken text never claims content the
        // screen does not show.
        if let text = message.decryptedText, !text.isEmpty {
            parts.append(text)
        } else if message.contentType == .text || message.decryptedText == nil {
            parts.append(message.placeholderText)
        }

        if let reactionsLabel {
            parts.append(reactionsLabel)
        }

        if message.sendState == .failed {
            parts.append("Not delivered")
        } else {
            parts.append(message.createdAt.formatted(date: .omitted, time: .shortened))
            if message.editedAt != nil { parts.append("edited") }
            if isMine, ChatFeatureFlags.readReceiptDisplay, let receiptLabel {
                parts.append(receiptLabel)
            }
        }

        return parts.joined(separator: ", ")
    }

    // MARK: Bubble

    private var bubble: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if let replyPreview {
                HStack(spacing: 6) {
                    Rectangle()
                        // A sent bubble is filled with `Theme.Colors.brand`, which is
                        // adaptive — so a fixed white quote bar was drawn against the
                        // dark-mode mint it was never measured on. `onBrand` is the
                        // foreground that tracks the accent in both appearances.
                        .fill(isMine ? Theme.Colors.onBrand.opacity(0.6) : Theme.Colors.brand)
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
        // The bubble is a container; the sender name and the footer around it are
        // NOT — they sit on the canvas and stay light in both appearances, which
        // is why this is on `bubble` and not on `body`.
        .fwbThemedContainer()
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
                .fwbThemedContainer()
                // A bare emoji plus a bare numeral read as two unrelated fragments,
                // and the numeral is dropped entirely when only one person reacted —
                // so the count was guesswork. Name the reaction and say how many.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.reactionLabel(emoji: emoji, count: users.count))
            }
        }
        .font(Theme.Typography.caption)
        .padding(.horizontal, Theme.Spacing.xs)
    }

    /// Every reaction on the message, in the order they are drawn.
    private var reactionsLabel: String? {
        guard !message.reactions.isEmpty else { return nil }
        return message.reactions
            .sorted { $0.key < $1.key }
            .map { Self.reactionLabel(emoji: $0.key, count: $0.value.count) }
            .joined(separator: ", ")
    }

    private static func reactionLabel(emoji: String, count: Int) -> String {
        let name = ChatReactionLabels.name(for: emoji)
        return count > 1 ? "\(name), \(count) reactions" : "\(name) reaction"
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

                if isMine, ChatFeatureFlags.readReceiptDisplay {
                    receiptGlyph
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.xs)
    }

    /// Read beats delivered beats sent. The counts come from the server's recipient
    /// rows — the client has no independent view of another member's devices, so
    /// there is nothing to compute here, only to render.
    private var receiptGlyph: some View {
        Group {
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
        // One filled checkmark versus a hollow one is the entire difference between
        // "read" and "delivered", and neither glyph carried a word — the distinction
        // simply did not exist without sight. `receiptLabel` is the same source the
        // bubble's spoken label uses, so the two can never drift apart.
        .accessibilityLabel(receiptLabel ?? "")
    }

    /// The delivery state as a word, or nil when nothing is drawn.
    private var receiptLabel: String? {
        switch message.sendState {
        case .pending: return "Sending"
        case .failed: return nil
        case .sent:
            if message.readCount > 0 { return "Read" }
            if message.deliveredCount > 0 { return "Delivered" }
            return "Sent"
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
        .fwbThemedContainer()
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
