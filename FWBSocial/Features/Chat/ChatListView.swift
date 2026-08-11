import SwiftUI

// MARK: - Conversation list
//
// Ported from Cove's `ConversationListView` (1,384 LoC — report 02 rates it
// "cleanly reusable") minus every entry point that died with the pruned features:
// no Off-Grid banner, no nudge row, no Deep End, no Stash, no Reunion radar.
//
// The unread badge is **server-authoritative**. `UnreadCountService` derives every
// unread surface — this list, the app badge, the per-recipient push badge — from one
// raw-SQL predicate, so a client-side count could only ever disagree with itself.

struct ChatListView: View {
    @State private var chat = ChatService.shared
    @State private var isPresentingNew = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let error = chat.enrolmentError {
                enrolmentFailure(error)
            } else if chat.conversations.isEmpty && !chat.isLoadingConversations {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Chat")
        .navigationBarTitleDisplayMode(.large)
        .rootSurfaceChrome()
        .floatingAction(
            isVisible: true,
            systemImage: "square.and.pencil",
            label: "New conversation"
        ) { isPresentingNew = true }
        .sheet(isPresented: $isPresentingNew) {
            NavigationStack { NewConversationView() }
        }
        .task {
            await chat.start()
            await HistoryHandoffService.shared.resumeIfNeeded()
        }
        .refreshable { await chat.refreshConversations() }
        .alert("Something went wrong", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: List

    private var list: some View {
        List {
            if !chat.pendingDevices.isEmpty {
                Section {
                    NavigationLink {
                        DeviceManagementView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(chat.pendingDevices.count) device waiting for approval")
                                    .font(Theme.Typography.rowTitle)
                                Text("Approve it from here to give it your history.")
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "iphone.badge.exclamationmark")
                                .foregroundStyle(Theme.Colors.caution)
                        }
                    }
                    .accessibilityIdentifier("chat.pendingDevices")
                }
            }

            if !OfflineQueueService.shared.isOnline || OfflineQueueService.shared.queuedCount > 0 {
                Section {
                    Label(
                        OfflineQueueService.shared.isOnline
                            ? "\(OfflineQueueService.shared.queuedCount) message waiting to send"
                            : "You're offline — messages will send when you're back",
                        systemImage: OfflineQueueService.shared.isOnline ? "arrow.up.circle" : "wifi.slash"
                    )
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(chat.conversations) { conversation in
                    NavigationLink {
                        ChatThreadView(conversationId: conversation.id)
                    } label: {
                        ConversationRow(conversation: conversation)
                    }
                    .accessibilityIdentifier("chat.conversation.\(conversation.id.uuidString)")
                }
            }
        }
        .listStyle(.plain)
    }

    private var emptyState: some View {
        EmptyStateView(
            icon: "lock.shield",
            title: "No conversations yet",
            // No action button: the floating button in the corner IS this action,
            // and offering the same verb twice reads as two different things.
            message: "Messages here are end-to-end encrypted — we can't read them, and neither can anyone else. Tap the button to start one with a friend."
        )
    }

    private func enrolmentFailure(_ error: String) -> some View {
        EmptyStateView(
            icon: "exclamationmark.lock",
            title: "Couldn't set up this device",
            message: "\(error)\n\nChat needs an encryption key on this device before it can send or receive.",
            actionTitle: "Try again",
            action: { Task { await chat.registerDeviceIfNeeded() } }
        )
    }
}

// MARK: - Row

private struct ConversationRow: View {
    let conversation: ChatConversation
    @State private var chat = ChatService.shared

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            AvatarView(name: chat.title(for: conversation), url: conversation.avatarUrl)
                .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(chat.title(for: conversation))
                        .font(Theme.Typography.rowTitle)
                        .lineLimit(1)
                    if conversation.muted {
                        Image(systemName: "bell.slash.fill")
                            .font(Theme.Typography.micro)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(subtitle)
                    .font(Theme.Typography.preview)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Spacing.sm)

            VStack(alignment: .trailing, spacing: 6) {
                if let date = conversation.lastMessageAt {
                    Text(date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                        .font(Theme.Typography.micro)
                        .foregroundStyle(.tertiary)
                }
                if conversation.unreadCount > 0 {
                    Text("\(conversation.unreadCount)")
                        .font(Theme.Typography.badge)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Theme.Colors.brand, in: Capsule())
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// **No message preview here, deliberately.** The list is built from the
    /// conversation route, which returns metadata only — and a preview would mean
    /// decrypting the last message of every thread on every list load. The honest
    /// subtitle is what the thread is, not what was said in it.
    private var subtitle: String {
        if conversation.isGroup {
            return "\(conversation.memberIds.count) people"
        }
        return conversation.requireQuantum ? "Quantum-secure" : "Encrypted"
    }
}
