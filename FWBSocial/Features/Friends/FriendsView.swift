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
    @State private var codeDraft = ""
    @State private var lookupResult: FriendCodeLookupResponse?
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("ABCD1234", text: $codeDraft)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .monospaced()
                        .accessibilityIdentifier("friends.code")
                    Button("Find") { Task { await lookup() } }
                        .disabled(codeDraft.trimmingCharacters(in: .whitespaces).count != 8 || isWorking)
                }

                if let lookupResult {
                    HStack(spacing: Theme.Spacing.md) {
                        AvatarView(name: lookupResult.displayName, url: lookupResult.avatarUrl)
                            .frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(lookupResult.displayName).font(Theme.Typography.rowTitle)
                            if let username = lookupResult.username {
                                Text("@\(username)").font(Theme.Typography.micro).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Add") { Task { await sendRequest(to: lookupResult.userId) } }
                            .buttonStyle(FWBPrimaryButtonStyle())
                            .disabled(isWorking)
                            .accessibilityIdentifier("friends.add")
                    }
                }
            } header: {
                Text("Add by friend code")
            } footer: {
                Text("Your own code is on your profile. Codes are exact — there's no search, on purpose.")
            }

            if !requests.isEmpty {
                Section("Requests") {
                    ForEach(requests) { request in
                        HStack(spacing: Theme.Spacing.md) {
                            AvatarView(name: request.fromDisplayName ?? "Member", url: nil)
                                .frame(width: 36, height: 36)
                            Text(request.fromDisplayName ?? "Someone")
                                .font(Theme.Typography.rowTitle)
                            Spacer()
                            Button("Accept") { Task { await respond(request, accept: true) } }
                                .buttonStyle(FWBPrimaryButtonStyle())
                            Button("Decline") { Task { await respond(request, accept: false) } }
                                .buttonStyle(FWBSecondaryButtonStyle())
                        }
                        .disabled(isWorking)
                    }
                }
            }

            Section {
                if isLoading {
                    ProgressView()
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
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { Task { await unfriend(friend) } }
                        }
                    }
                }
            } header: {
                Text("Friends")
            }

            if let statusMessage {
                Section { Text(statusMessage).font(Theme.Typography.caption).foregroundStyle(.secondary) }
            }
            if let errorMessage {
                Section { FormErrorText(message: errorMessage) }
            }
        }
        .navigationTitle("Friends")
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: Actions

    private func load() async {
        defer { isLoading = false }
        friends = (try? await FriendsAPI.friends()) ?? []
        requests = (try? await FriendsAPI.incomingRequests()) ?? []
    }

    private func lookup() async {
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        lookupResult = nil
        do {
            lookupResult = try await FriendsAPI.lookup(code: codeDraft.trimmingCharacters(in: .whitespaces))
        } catch {
            // One message for every refusal. Saying "that code doesn't exist" versus
            // "they blocked you" would turn this into an oracle.
            errorMessage = "No member with that code."
        }
    }

    private func sendRequest(to userId: UUID) async {
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await FriendsAPI.sendRequest(to: userId, source: .friendCode)
            statusMessage = "Request sent."
            lookupResult = nil
            codeDraft = ""
            await load()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func respond(_ request: FriendRequestDTO, accept: Bool) async {
        isWorking = true
        defer { isWorking = false }
        _ = accept
            ? try? await FriendsAPI.accept(request.id)
            : try? await FriendsAPI.decline(request.id)
        await load()
    }

    private func unfriend(_ friend: FriendDTO) async {
        try? await FriendsAPI.unfriend(friend.userId)
        await load()
    }

    private func message(_ friend: FriendDTO) async {
        guard let conversation = try? await ChatService.shared.startDirectConversation(with: friend.userId) else {
            errorMessage = "You can't start a conversation with them right now."
            return
        }
        AppState.shared.openConversation(id: conversation.id)
    }
}
