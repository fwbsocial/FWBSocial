import SwiftUI

// MARK: - Blocked members
//
// Guideline 1.2 wants blocking to be reversible and inspectable, not a one-way
// door — so the list exists as much to let someone undo a block as to confirm
// one landed.
//
// The copy is careful about two things the server actually does:
//   1. Unblocking does **not** restore what the block tore down. A severed
//      friendship stays severed and must be re-established deliberately.
//   2. Blocking does **not** eject either party from a shared group conversation
//      (plan §4.4 defers that to v1.1 as a product decision). Chat lands in
//      Phase 6, so the caveat is written now and shown once there is chat to
//      caveat — stating it here today would describe a feature that doesn't
//      exist yet.

struct BlockedMembersView: View {

    @Environment(ToastCenter.self) private var toasts
    @State private var blocks = BlockStore.shared

    @State private var members: [BlockedUserResponse] = []
    @State private var isLoading = false
    // Phase 8: the failure is kept as an `Error`, not as a pre-flattened string,
    // so the view can still ask whether it was the network (offline branch) after
    // the fact. Flattening at the `catch` threw that away.
    @State private var loadError: Error?
    @State private var pendingUnblock: BlockedUserResponse?

    var body: some View {
        List {
            if let loadError {
                Section {
                    // A failure with nothing on screen gets the whole surface; a
                    // failure over a list that already loaded gets one line, because
                    // replacing content the member can still read is a worse trade.
                    if members.isEmpty {
                        ErrorStateView(error: loadError) { Task { await load() } }
                            .listRowBackground(Color.clear)
                    } else {
                        InlineErrorRow(message: loadError.fwbMessage) { Task { await load() } }
                    }
                }
            }

            // `loadError == nil` is the whole point: "Nobody blocked" is a claim
            // about the server's answer, and a failed request is not an answer.
            if members.isEmpty && !isLoading && loadError == nil {
                Section {
                    EmptyStateView(
                        icon: "hand.raised",
                        title: "Nobody blocked",
                        message: "Block someone from their profile and they'll show up here.")
                    .listRowBackground(Color.clear)
                }
            }

            ForEach(members) { member in
                HStack(spacing: Theme.Spacing.md) {
                    HStack(spacing: Theme.Spacing.md) {
                        AvatarView(name: member.name, url: nil, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.name)
                                .font(Theme.Typography.rowTitle)
                            if let username = member.username {
                                Text("@\(username)")
                                    .font(Theme.Typography.micro)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    // One element, and `.ignore` rather than `.combine` because the
                    // avatar's initials are a `Text` too — combining would have
                    // VoiceOver read "BN, Bea Nolan, @bea" for every row.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(member.username.map { "\(member.name), @\($0)" } ?? member.name)

                    Spacer()
                    Button("Unblock") { pendingUnblock = member }
                        .font(Theme.Typography.caption)
                        .buttonStyle(.bordered)
                        // Every row's button announced the bare word "Unblock", so a
                        // list of blocked members offered a VoiceOver user several
                        // identical controls and no way to tell whose block they were
                        // about to lift.
                        .accessibilityLabel("Unblock \(member.name)")
                }
            }

            if isLoading {
                Section {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }
        }
        .navigationTitle("Blocked")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog(
            pendingUnblock.map { "Unblock \($0.name)?" } ?? "Unblock?",
            isPresented: Binding(
                get: { pendingUnblock != nil },
                set: { if !$0 { pendingUnblock = nil } }),
            titleVisibility: .visible
        ) {
            Button("Unblock") {
                if let member = pendingUnblock { unblock(member) }
                pendingUnblock = nil
            }
            Button("Cancel", role: .cancel) { pendingUnblock = nil }
        } message: {
            Text("You'll start seeing their posts and comments again. Any friendship the block removed is not restored.")
        }
    }

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            members = try await APIClient.shared.blockedUsers()
            await blocks.refresh()
        } catch {
            guard !isCancellationError(error) else { isLoading = false; return }
            self.loadError = error
        }
        isLoading = false
    }

    private func unblock(_ member: BlockedUserResponse) {
        Task {
            do {
                try await APIClient.shared.unblock(userId: member.userId)
                blocks.markUnblocked(member.userId)
                members.removeAll { $0.userId == member.userId }
                toasts.success("Unblocked \(member.name).")
            } catch {
                guard !isCancellationError(error) else { return }
                toasts.error(error.fwbMessage)
            }
        }
    }
}

#Preview {
    NavigationStack { BlockedMembersView() }
        .environment(ToastCenter())
}
