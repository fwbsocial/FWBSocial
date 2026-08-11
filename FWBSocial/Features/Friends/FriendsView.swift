import SwiftUI

// MARK: - Friends
//
// PLAN.md Phase 6 ports the friend graph alongside chat for one blunt reason: chat is
// untestable without it. `inbox_policy` defaults to `friends_only`, so with no
// friends nobody can message anybody.
//
// **Commissioner decision 9 removes member search entirely, in v1 and after.**
// Discovery is exactly three paths and this screen exposes two of them:
//   1. an exact friend-code lookup — an 8-character shared secret its owner handed
//      out deliberately, rate-limited server-side because a code that short would
//      otherwise be enumerable;
//   2. incoming requests to accept or decline.
// The third (tapping a member on their forum post) lives in `AuthorProfileSheet`,
// and the recipient can switch it off.
//
// Every refusal returns the SAME 404 — "no such code", "that's you", and "one of you
// blocked the other" are indistinguishable on purpose.

struct FriendsView: View {
    @State private var friends: [FriendDTO] = []
    @State private var requests: [FriendRequestDTO] = []
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var errorMessage: String?
    /// The list failed to load, as opposed to an individual action failing.
    @State private var loadError: Error?

    var body: some View {
        Form {
            // The entry flow itself lives in `AddFriendByCode.swift` — the Events
            // tab and the event roster present the same thing as a sheet, and a
            // lookup whose defining property is that all its failures look alike
            // must not exist in three copies.
            AddFriendByCodeSection { Task { await load() } }

            if !requests.isEmpty {
                Section("Requests") {
                    ForEach(requests) { request in
                        // Both button styles apply `.frame(maxWidth: .infinity)`, so
                        // two of them side by side already fill the row at default
                        // sizes and overflow it outright at accessibility sizes.
                        // `ViewThatFits` keeps the one-line arrangement while it
                        // fits and stacks the pair underneath the name when it
                        // cannot.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: Theme.Spacing.md) {
                                requestIdentity(request)
                                Spacer()
                                requestActions(request)
                            }
                            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                                HStack(spacing: Theme.Spacing.md) {
                                    requestIdentity(request)
                                    Spacer()
                                }
                                requestActions(request)
                            }
                        }
                        .disabled(isWorking)
                    }
                }
            }

            Section {
                if isLoading {
                    ProgressView()
                } else if let loadError {
                    // Ahead of the empty state: "No friends yet" is a claim about
                    // this member's social graph, and a failed fetch does not
                    // entitle the app to make it.
                    ErrorStateView(error: loadError) { Task { await load() } }
                        .listRowBackground(Color.clear)
                } else if friends.isEmpty {
                    Text("No friends yet. Add someone with their code, or meet people through an event's friending window.")
                        .font(Theme.Typography.preview)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(friends) { friend in
                        HStack(spacing: Theme.Spacing.md) {
                            AvatarView(name: friend.displayName, url: friend.avatarUrl)
                                .frame(width: 36, height: 36)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(friend.displayName).font(Theme.Typography.rowTitle)
                                if let since = friend.friendsSince {
                                    Text("Friends since \(since, format: .dateTime.month().year())")
                                        .font(Theme.Typography.micro)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button {
                                Task { await message(friend) }
                            } label: {
                                Image(systemName: "bubble.left.and.text.bubble.right")
                            }
                            .accessibilityIdentifier("friends.message.\(friend.userId.uuidString)")
                            // The name has to be in the label: every row's button
                            // is otherwise the same unlabelled glyph, so VoiceOver
                            // gave no way to tell whom you were about to message.
                            .accessibilityLabel("Message \(friend.displayName)")
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { Task { await unfriend(friend) } }
                        }
                    }
                }
            } header: {
                Text("Friends")
            }

            // "Request sent." now belongs to the shared section that sent it; what
            // is left here reports the actions this screen still owns — accept,
            // decline, unfriend, start a conversation.
            if let errorMessage {
                Section { FormErrorText(message: errorMessage) }
            }
        }
        .navigationTitle("Friends")
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: Request row pieces
    //
    // Split out so the one-line and stacked arrangements above are two layouts of
    // the same content rather than two copies of it.

    @ViewBuilder
    private func requestIdentity(_ request: FriendRequestDTO) -> some View {
        AvatarView(name: request.fromDisplayName ?? "Member", url: nil)
            .frame(width: 36, height: 36)
        Text(request.fromDisplayName ?? "Someone")
            .font(Theme.Typography.rowTitle)
    }

    private func requestActions(_ request: FriendRequestDTO) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Button("Accept") { Task { await respond(request, accept: true) } }
                .buttonStyle(FWBPrimaryButtonStyle())
            Button("Decline") { Task { await respond(request, accept: false) } }
                .buttonStyle(FWBSecondaryButtonStyle())
        }
    }

    // MARK: Actions

    private func load() async {
        defer { isLoading = false }
        loadError = nil
        do {
            // Both `try?`s used to collapse into `?? []`, which made a total
            // outage indistinguishable from genuinely having no friends — the
            // screen said "No friends yet. Add someone with their code" to a
            // member with a full friends list and no signal.
            friends = try await FriendsAPI.friends()
            requests = try await FriendsAPI.incomingRequests()
        } catch {
            guard !isCancellationError(error) else { return }
            loadError = error
        }
    }

    private func respond(_ request: FriendRequestDTO, accept: Bool) async {
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        do {
            // Previously two `try?`s: a request that failed to be accepted simply
            // stayed in the list, which looks identical to a tap that missed.
            if accept {
                _ = try await FriendsAPI.accept(request.id)
            } else {
                _ = try await FriendsAPI.decline(request.id)
            }
        } catch {
            guard !isCancellationError(error) else { return }
            errorMessage = error.fwbMessage
        }
        await load()
    }

    private func unfriend(_ friend: FriendDTO) async {
        errorMessage = nil
        do {
            try await FriendsAPI.unfriend(friend.userId)
        } catch {
            guard !isCancellationError(error) else { return }
            errorMessage = error.fwbMessage
        }
        await load()
    }

    private func message(_ friend: FriendDTO) async {
        errorMessage = nil
        do {
            let conversation = try await ChatService.shared.startDirectConversation(with: friend.userId)
            AppState.shared.openConversation(id: conversation.id)
        } catch {
            guard !isCancellationError(error) else { return }
            // The server distinguishes "they've blocked you", "your device isn't
            // enrolled yet" and "you aren't vetted" here, and each needs a
            // different response from the member. One flat sentence hid all three.
            errorMessage = error.fwbMessage
        }
    }
}
