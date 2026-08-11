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
    @State private var error: String?
    @State private var pendingUnblock: BlockedUserResponse?

    var body: some View {
        List {
            if let error {
                Section { FormErrorText(message: error) }
            }

            if members.isEmpty && !isLoading {
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
                    Spacer()
                    Button("Unblock") { pendingUnblock = member }
                        .font(Theme.Typography.caption)
                        .buttonStyle(.bordered)
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
        error = nil
        do {
            members = try await APIClient.shared.blockedUsers()
            await blocks.refresh()
        } catch {
            guard !isCancellationError(error) else { isLoading = false; return }
            self.error = error.localizedDescription
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
                toasts.error(error.localizedDescription)
            }
        }
    }
}

#Preview {
    NavigationStack { BlockedMembersView() }
        .environment(ToastCenter())
}
