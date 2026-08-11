import PhotosUI
import SwiftUI

// MARK: - Message thread
//
// Cove's `ChatView` is a 3,828-line monolith and report 02 rates it "reusable with
// surgery". The surgery PLAN.md §4.3.2 and §8 call for removes most of it: the
// Off-Grid P2P branch, the Direct Link send path, the genmoji / poll / song
// composers, the nudge affordances, and the Deep End entry point. What is left is
// the part that is actually a chat thread — bubbles, grouping, receipts, typing,
// reply, reactions, the composer, and the media seam — rebuilt around those pieces
// rather than carried across with the deletions left as scar tissue.

struct ChatThreadView: View {
    let conversationId: UUID

    @State private var chat = ChatService.shared
    @State private var draft = ""
    @State private var replyTo: ChatMessage?
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var pickerItem: PhotosPickerItem?
    @State private var actionTarget: ChatMessage?
    @State private var reportTarget: ChatMessage?

    private var conversation: ChatConversation? { chat.conversation(conversationId) }
    private var messages: [ChatMessage] { chat.messagesByConversation[conversationId] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            securityBanner
            transcript
            typingRow
            composer
        }
        .navigationTitle(conversation.map(chat.title(for:)) ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    ConversationSettingsView(conversationId: conversationId)
                } label: {
                    Label("Details", systemImage: "info.circle")
                }
                .accessibilityIdentifier("chat.details")
            }
        }
        .task {
            await chat.loadMessages(conversationId)
            await chat.markRead(conversationId)
        }
        .sheet(item: $actionTarget) { message in
            MessageActionMenu(
                message: message,
                isMine: chat.isMine(message),
                onReply: { replyTo = message },
                onReact: { emoji in Task { await chat.react(to: message.id, emoji: emoji, in: conversationId) } },
                onDelete: { Task { try? await chat.deleteMessage(message) } },
                onReport: { reportTarget = message }
            )
            .presentationDetents([.height(280)])
        }
        .sheet(item: $reportTarget) { message in
            ChatReportSheet(message: message, conversationId: conversationId)
        }
        .alert("Couldn't send", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await sendPhoto(item) }
        }
    }

    // MARK: - Security banner
    //
    // Blocking warnings mean a device was SKIPPED — its owner cannot read what was
    // sent on it. That is not a footnote; it goes at the top of the thread.

    @ViewBuilder
    private var securityBanner: some View {
        let warnings = chat.securityWarnings[conversationId] ?? []
        let blocking = warnings.filter(\.isBlocking)
        if !blocking.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(blocking) { warning in
                    Label(warning.message, systemImage: "exclamationmark.shield.fill")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.caution)
                }
                if let changed = chat.pendingKeyChanges[conversationId], !changed.isEmpty {
                    NavigationLink {
                        SafetyNumberView(conversationId: conversationId)
                    } label: {
                        Text("Verify the safety number")
                            .font(Theme.Typography.caption.weight(.semibold))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.md)
            .background(Theme.Colors.caution.opacity(0.12))
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if chat.hasMoreByConversation[conversationId] != false {
                        ProgressView()
                            .padding()
                            .task { await chat.loadOlderMessages(conversationId) }
                    }

                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        let previous = index > 0 ? messages[index - 1] : nil
                        let next = index < messages.count - 1 ? messages[index + 1] : nil

                        if shouldShowDateSeparator(message, after: previous) {
                            Text(message.createdAt, format: .dateTime.weekday(.wide).month().day())
                                .font(Theme.Typography.micro)
                                .foregroundStyle(.tertiary)
                                .padding(.vertical, Theme.Spacing.md)
                        }

                        MessageBubble(
                            message: message,
                            isMine: chat.isMine(message),
                            senderName: chat.isMine(message) ? nil : chat.name(for: message.senderId),
                            isGroup: conversation?.isGroup ?? false,
                            groupsWithPrevious: groups(message, with: previous),
                            groupsWithNext: groups(message, with: next),
                            replyPreview: replyPreview(for: message),
                            onTap: { actionTarget = message },
                            onRetry: { Task { await chat.retry(message) } }
                        )
                        .id(message.id)
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _, _ in
                guard let last = messages.last else { return }
                withAnimation(Theme.Motion.bubble) { proxy.scrollTo(last.id, anchor: .bottom) }
                Task { await chat.markRead(conversationId) }
            }
        }
    }

    @ViewBuilder
    private var typingRow: some View {
        let typing = chat.typingMembers(in: conversationId)
        if !typing.isEmpty {
            HStack {
                TypingBubble()
                Text(typing.map { chat.name(for: $0) }.joined(separator: ", ") + " is typing…")
                    .font(Theme.Typography.micro)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.bottom, Theme.Spacing.xs)
            .transition(.opacity)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 0) {
            if let replyTo {
                HStack(spacing: Theme.Spacing.sm) {
                    Rectangle()
                        .fill(Theme.Colors.brand)
                        .frame(width: 3)
                        .fwbCorner(2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(chat.isMine(replyTo) ? "You" : chat.name(for: replyTo.senderId))
                            .font(Theme.Typography.micro.weight(.semibold))
                        Text(replyTo.decryptedText ?? replyTo.placeholderText)
                            .font(Theme.Typography.micro)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        self.replyTo = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.sm)
                .background(Theme.Colors.surface)
            }

            HStack(alignment: .bottom, spacing: Theme.Spacing.sm) {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Image(systemName: "photo")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.Colors.brand)
                }
                // The label closure is `nonisolated` in iOS 26's PhotosPicker —
                // house gotcha `reference_ios26_photospicker_label_nonisolated`. It
                // reads only static theme values, so nothing crosses.
                .accessibilityIdentifier("chat.photo")

                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1 ... 5)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.sm)
                    .background(Theme.Colors.field, in: Capsule())
                    .accessibilityIdentifier("chat.composer")
                    .onChange(of: draft) { _, newValue in
                        Task { await chat.sendTyping(conversationId, isTyping: !newValue.isEmpty) }
                    }

                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(canSend ? Theme.Colors.brand : Color.secondary)
                }
                .disabled(!canSend)
                .accessibilityIdentifier("chat.send")
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
        }
        .background(.bar)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    private func send() async {
        let text = draft
        draft = ""
        let reply = replyTo
        replyTo = nil
        isSending = true
        defer { isSending = false }
        do {
            try await chat.send(conversationId: conversationId, text: text, replyToId: reply?.id)
            await chat.sendTyping(conversationId, isTyping: false)
        } catch {
            draft = text
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func sendPhoto(_ item: PhotosPickerItem) async {
        pickerItem = nil
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        isSending = true
        defer { isSending = false }
        do {
            try await chat.send(
                conversationId: conversationId,
                text: "",
                contentType: .image,
                mediaData: data,
                mediaMimeType: "image/jpeg"
            )
        } catch {
            // R2 is not provisioned yet, and the server says so with a 503 and a
            // renderable sentence rather than a 500. Surface it verbatim.
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Grouping

    /// Consecutive messages from one sender inside five minutes read as one stack —
    /// only the group's outer edges are fully rounded (`GroupedBubbleShape`).
    private func groups(_ message: ChatMessage, with other: ChatMessage?) -> Bool {
        guard let other else { return false }
        return other.senderId == message.senderId
            && abs(other.createdAt.timeIntervalSince(message.createdAt)) < 300
    }

    private func shouldShowDateSeparator(_ message: ChatMessage, after previous: ChatMessage?) -> Bool {
        guard let previous else { return true }
        return !Calendar.current.isDate(previous.createdAt, inSameDayAs: message.createdAt)
    }

    private func replyPreview(for message: ChatMessage) -> String? {
        guard let replyToId = message.replyToId,
              let target = messages.first(where: { $0.id == replyToId }) else { return nil }
        return target.decryptedText ?? target.placeholderText
    }
}
