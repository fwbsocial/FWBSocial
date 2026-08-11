import SwiftUI

// MARK: - New conversation
//
// Ported from Cove's `NewMessageView` (ConversationListView 1171–1384) with one
// structural change forced by **commissioner decision 9: there is no member search
// in v1, and there must never be one.** Cove let you search every user; here the
// only people you can start a conversation with are your friends, because discovery
// is exactly three paths (friend code, post-event window, forum-profile tap) and
// none of them is a directory.
//
// The Message button is gated on `GET /api/chat/can-message/:userId` rather than on
// a guess: `inbox_policy` defaults to `friends_only`, blocks are symmetric and
// silent, and finding out after composing a message is the worst possible time. The
// probe returns an **identical shape for every refusal** — do not try to render a
// reason from it, because distinguishing "blocked" from "closed inbox" would be a
// block-detection oracle.

struct NewConversationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var chat = ChatService.shared
    @State private var friends: [FriendDTO] = []
    @State private var isLoading = true
    @State private var isGroup = false
    @State private var groupTitle = ""
    @State private var selected: Set<UUID> = []
    @State private var unreachable: Set<UUID> = []
    @State private var errorMessage: String?
    /// The friend-list load's own failure, kept apart from `errorMessage` (which
    /// belongs to the Start action) because the two need different treatments: this
    /// one replaces the list, that one sits under it.
    @State private var loadError: Error?

    var body: some View {
        Form {
            Section {
                Toggle("Group conversation", isOn: $isGroup.animation())
                if isGroup {
                    TextField("Group name (optional)", text: $groupTitle)
                }
            }

            Section {
                if isLoading {
                    ProgressView()
                } else if let loadError {
                    // loading → error → empty → content. "No friends yet" is a claim
                    // about the server's answer, and a request that failed is not an
                    // answer: the member was being told they have no friends and
                    // pointed at the friend-code flow because a fetch timed out.
                    ErrorStateView(error: loadError) { Task { await load() } }
                        .listRowBackground(Color.clear)
                } else if friends.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text("No friends yet")
                            .font(Theme.Typography.rowTitle)
                        Text("Add someone with their friend code, or meet people at an event — the attendee list opens for 48 hours after it ends.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)
                        NavigationLink("Add a friend") { FriendsView() }
                            .font(Theme.Typography.caption.weight(.semibold))
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                } else {
                    ForEach(friends) { friend in
                        friendRow(friend)
                    }
                }
            } header: {
                Text(isGroup ? "Who's in it?" : "Who do you want to message?")
            } footer: {
                if !unreachable.isEmpty {
                    Text("Some people can't be added right now. That can mean their inbox is set to friends only, or they aren't available to you.")
                }
            }

            if let errorMessage {
                Section { FormErrorText(message: errorMessage) }
            }
        }
        .navigationTitle("New conversation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Start") { Task { await start() } }
                    .disabled(selected.isEmpty)
                    .accessibilityIdentifier("chat.new.start")
            }
        }
        .task { await load() }
    }

    private func friendRow(_ friend: FriendDTO) -> some View {
        Button {
            guard !unreachable.contains(friend.userId) else { return }
            if isGroup {
                if selected.contains(friend.userId) { selected.remove(friend.userId) } else { selected.insert(friend.userId) }
            } else {
                selected = [friend.userId]
            }
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                AvatarView(name: friend.displayName, url: friend.avatarUrl)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(friend.displayName).font(Theme.Typography.rowTitle)
                    if unreachable.contains(friend.userId) {
                        Text("Not available")
                            .font(Theme.Typography.micro)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if selected.contains(friend.userId) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Colors.brand)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        // The label is an HStack with a `Spacer()` in it, and a `.plain` button
        // only takes hits on its actual content — so the whole middle of the row,
        // which is the biggest and most obvious place to aim, was a hole. Tapping
        // there selected nobody and left Start disabled, which reads as the button
        // being broken rather than as the tap having missed. Found by a UI test
        // whose centred tap landed in the gap.
        .contentShape(Rectangle())
        .foregroundStyle(unreachable.contains(friend.userId) ? Color.secondary : Color.primary)
        // Group selection was carried entirely by a checkmark glyph, so VoiceOver
        // read a picked and an unpicked friend identically — with no way to check
        // who is in the group before tapping Start.
        .accessibilityAddTraits(selected.contains(friend.userId) ? [.isSelected] : [])
        .accessibilityIdentifier("chat.new.friend.\(friend.userId.uuidString)")
    }

    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            friends = try await FriendsAPI.friends()
        } catch {
            // A cancelled load is the member navigating away, not a failure worth
            // showing them when they come back.
            guard !isCancellationError(error) else { return }
            friends = []
            loadError = error
            return
        }

        // Probe each friend once so the row can grey out before the member commits
        // to composing anything.
        for friend in friends {
            if let probe = await chat.canMessage(friend.userId), !probe.canMessage {
                unreachable.insert(friend.userId)
            }
        }
    }

    private func start() async {
        do {
            let conversation: ChatConversation
            if isGroup {
                let trimmed = groupTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                conversation = try await chat.createGroup(
                    title: trimmed.isEmpty ? nil : trimmed,
                    memberIds: Array(selected)
                )
            } else {
                guard let target = selected.first else { return }
                conversation = try await chat.startDirectConversation(with: target)
            }
            dismiss()
            AppState.shared.pendingConversationId = conversation.id
        } catch {
            errorMessage = error.fwbMessage
        }
    }
}
