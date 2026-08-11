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

    var body: some View {
        Group {
            if let error = chat.enrolmentError {
                enrolmentFailure(error)
            } else if chat.conversations.isEmpty, !chat.isLoadingConversations,
                      let failure = chat.conversationsError {
                // Ahead of the empty state deliberately. `ChatService` used to log
                // and drop this error, so a member with no signal was shown "No
                // conversations yet" — a confident, friendly claim about their
                // account that the app had no basis for.
                ErrorStateView(error: failure) { Task { await chat.refreshConversations() } }
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
            label: "New",
            voiceOverLabel: "New message"
        ) { isPresentingNew = true }
        .sheet(isPresented: $isPresentingNew) {
            NavigationStack { NewConversationView() }
        }
        .task {
            await chat.start()
            await HistoryHandoffService.shared.resumeIfNeeded()
        }
        .refreshable { await chat.refreshConversations() }
    }

    // MARK: List

    private var list: some View {
        List {
            Group {
                // A refresh that failed over a list that already has content: one line,
                // not a takeover. The conversations on screen are still real.
                if let failure = chat.conversationsError {
                    Section {
                        InlineErrorRow(message: failure.fwbMessage) {
                            Task { await chat.refreshConversations() }
                        }
                    }
                }

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
                            // The same surface `RootTabView`'s `navigationDestination`
                            // gives a thread opened from a push. A thread opened from
                            // this row is a different push site and needs its own.
                            ChatThreadView(conversationId: conversation.id)
                                .fwbAppThemeSurface()
                        } label: {
                            ConversationRow(conversation: conversation)
                        }
                        .accessibilityIdentifier("chat.conversation.\(conversation.id.uuidString)")
                    }
                }
            }
            // A plain list draws an opaque `systemBackground` behind every
            // row — which is why the conversation list was a black band across
            // the painting. The empty and error rows opt back out with their
            // own `.listRowBackground(.clear)`, which is closer and still wins.
            .fwbThemedRows()
        }
        .listStyle(.plain)
    }

    private var emptyState: some View {
        // ScrollView container matches Feed's empty-state geometry exactly — bare,
        // the full-screen theme surface centered this vertically while Feed's
        // starts under the title (owner: align the two).
        ScrollView {
            EmptyStateView(
                icon: "message.fill",
                title: "No conversations yet",
                // No action button: the compose slot in the tab bar IS this action,
                // and offering the same verb twice reads as two different things.
                message: "Messages here are end-to-end encrypted — we can't read them, and neither can anyone else. Tap the button to start one with a friend."
            )
            .padding()
        }
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
                        // The busiest row in the app — avatar, title, mute glyph,
                        // date and unread badge on one line. The title is the part
                        // that identifies the conversation, so it is the part that
                        // gets to grow when everything else cannot.
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
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
                        // Over the brand-filled capsule, so it follows the accent
                        // between appearances rather than staying white on mint.
                        .foregroundStyle(Theme.Colors.onBrand)
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
