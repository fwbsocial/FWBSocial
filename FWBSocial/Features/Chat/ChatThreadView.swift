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
    @State private var mediaTarget: ChatMessage?

    private var conversation: ChatConversation? { chat.conversation(conversationId) }
    private var messages: [ChatMessage] { chat.messagesByConversation[conversationId] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            securityBanner
            transcript
            if ChatFeatureFlags.typingIndicators { typingRow }
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
                // A delete that silently failed left the message on screen with no
                // explanation, which reads as the app ignoring the tap — and on a
                // message someone regrets sending, "it looked like it didn't work"
                // is the wrong ambiguity to leave.
                onDelete: {
                    Task {
                        do { try await chat.deleteMessage(message) }
                        catch {
                            guard !isCancellationError(error) else { return }
                            errorMessage = error.fwbMessage
                        }
                    }
                },
                onReport: { reportTarget = message }
            )
            // 280 pt fits the menu at default sizes and hides its LAST row at
            // accessibility sizes — and the last rows are Delete and Report, which
            // are exactly the two a member most needs to reach. `.medium` and
            // `.large` are offered alongside so the sheet has somewhere to grow.
            .presentationDetents([.height(280), .medium, .large])
        }
        .sheet(item: $reportTarget) { message in
            ChatReportSheet(message: message, conversationId: conversationId)
        }
        .fullScreenCover(item: $mediaTarget) { message in
            ChatMediaViewer(message: message)
        }
        // Carries send failures and delete failures both, so the title stays
        // neutral; the body is the server's own sentence either way.
        .alert("Couldn't do that", isPresented: .constant(errorMessage != nil)) {
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
                    // A history fetch that failed used to leave the transcript
                    // simply blank. On an end-to-end-encrypted app a blank
                    // transcript does not read as "couldn't load" — it reads as
                    // "your messages are gone", which is the most alarming thing
                    // this app can imply and the one it can least afford to imply
                    // by accident.
                    if messages.isEmpty, let failure = chat.historyErrors[conversationId] {
                        ErrorStateView(error: failure) {
                            Task { await chat.loadMessages(conversationId) }
                        }
                        .padding(.top, Theme.Spacing.xxl)
                    } else if messages.isEmpty, chat.hasMoreByConversation[conversationId] == false {
                        EmptyStateView(
                            icon: "lock.shield",
                            title: "No messages yet",
                            message: "Say something. Everything in this thread is end-to-end encrypted — the server stores it, but cannot read it.")
                        .padding(.top, Theme.Spacing.xxl)
                    }

                    // `hasMore` is unset until a page lands, so on a failed history
                    // fetch this spinner used to sit above the error state
                    // retrying forever. Nothing to page through until the first
                    // page succeeds.
                    if chat.hasMoreByConversation[conversationId] != false,
                       chat.historyErrors[conversationId] == nil {
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
                            replyPreview: ChatFeatureFlags.replyQuoting ? replyPreview(for: message) : nil,
                            onTap: { actionTarget = message },
                            onOpenMedia: { mediaTarget = message },
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
            if ChatFeatureFlags.replyQuoting, let replyTo {
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
                    .accessibilityLabel("Cancel reply")
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
                .accessibilityLabel("Send a photo")

                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1 ... 5)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.sm)
                    .background(Theme.Colors.field, in: Capsule())
                    .accessibilityIdentifier("chat.composer")
                    .onChange(of: draft) { _, newValue in
                        guard ChatFeatureFlags.typingIndicators else { return }
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
                // The one icon-only control a chat app cannot afford to leave
                // unlabelled. `PostDetailView`'s send button already labels itself;
                // this one was announcing as a bare "Button".
                .accessibilityLabel("Send")
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
            if ChatFeatureFlags.typingIndicators {
                await chat.sendTyping(conversationId, isTyping: false)
            }
        } catch {
            draft = text
            errorMessage = error.fwbMessage
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
            errorMessage = error.fwbMessage
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
