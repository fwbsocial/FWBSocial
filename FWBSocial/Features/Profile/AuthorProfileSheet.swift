import SwiftUI

// MARK: - Author profile sheet
//
// Commissioner decision 9: **there is no member search in v1.** Discovery is
// (a) post-event friending windows and (b) tapping someone on their forum posts
// and comments. This sheet is the whole of (b), which makes it the only way to
// reach a person from the forum.
//
// **It fetches nothing.** There is no member-facing user endpoint on the server —
// `searchUsers` was removed with decision 9 and no `/api/users/:id` replaced it
// (verified against `routes.swift`: the only `users` routes are admin ban/roles).
// The server's `ForumAuthor` comment is explicit that this is deliberate: the
// shape "carries enough to render a person without a second round trip." So this
// sheet is a pure projection of the author already embedded in the post or
// comment, and it cannot show anything that isn't on that wire shape.
//
// One honest consequence, recorded rather than papered over: the **vetted badge
// is inferred, not fetched.** `ForumAuthor` carries no vetting field. Everything
// under `/api/channels/*` sits behind `RequireVettedMember`, so anyone whose
// content appears in a channel is necessarily vetted (or an admin) — the badge
// states a fact that is true by construction of the surface it was tapped from.
// That is why `isVettedContext` is a parameter: a future non-vetted surface must
// pass false rather than inherit a claim that stops being true.

struct AuthorProfileSheet: View {

    let author: ForumAuthor
    /// True when the author was tapped from a surface that only vetted members
    /// can post to. See the note above — this is what licenses the badge.
    var isVettedContext: Bool = true

    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts
    @State private var blocks = BlockStore.shared

    @State private var reportTarget: ReportTargetDescriptor?
    @State private var isConfirmingBlock = false
    @State private var isWorking = false

    private var isBlocked: Bool { blocks.isBlocked(author.id) }
    private var isMe: Bool { AuthService.shared.user?.id == author.id }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.xl) {
                    header

                    if isBlocked {
                        blockedNotice
                    } else {
                        actions
                    }
                }
                .padding()
            }
            .navigationTitle("Member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fwbReportSheet($reportTarget)
            .confirmationDialog(
                "Block \(author.name)?",
                isPresented: $isConfirmingBlock,
                titleVisibility: .visible
            ) {
                Button("Block", role: .destructive) { block() }
                Button("Cancel", role: .cancel) { }
            } message: {
                // The server's unblock path does not restore what a block tears
                // down, so the copy says so before the choice, not after.
                Text("You won't see their posts or comments. Any friendship or pending request is removed and unblocking later won't restore it.")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: Theme.Spacing.md) {
            AvatarView(name: author.name, url: author.avatarUrl, size: 88)

            VStack(spacing: 4) {
                Text(author.name)
                    .font(Theme.Typography.title)
                    .multilineTextAlignment(.center)

                if let handle = author.handle {
                    Text(handle)
                        .font(Theme.Typography.preview)
                        .foregroundStyle(.secondary)
                }
            }

            if isVettedContext && !author.isTombstoned {
                StatusBadge("Vetted member", color: Theme.Colors.positive)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Spacing.lg)
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: Theme.Spacing.md) {
            if !isMe && !author.isTombstoned {
                friendRequestButton

                Button {
                    reportTarget = ReportTargetDescriptor(
                        targetType: .user,
                        targetId: author.id,
                        subjectName: author.name,
                        blockableUserId: author.id)
                } label: {
                    Label("Report member", systemImage: "flag")
                }
                .buttonStyle(FWBSecondaryButtonStyle())

                Button(role: .destructive) {
                    isConfirmingBlock = true
                } label: {
                    Label("Block member", systemImage: "hand.raised")
                        .foregroundStyle(Theme.Colors.danger)
                }
                .buttonStyle(FWBSecondaryButtonStyle())
            }

            if author.isTombstoned {
                Text("This member deleted their account. Their posts stay under a placeholder name.")
                    .font(Theme.Typography.preview)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .disabled(isWorking)
    }

    /// **Ships inert on purpose.** The friend-request endpoint arrives with the
    /// Phase 6 social graph; gating on `FWBFeatures.friendRequests` means the
    /// surface is written, reviewed and built now, and turning it on later is one
    /// constant — not a UI project competing with chat for attention.
    ///
    /// Two gates, not one: the feature flag *and* the target's own
    /// `allowsFriendRequests` (decision 9's per-user setting). Offering a button
    /// the recipient has switched off would be a promise the server will refuse.
    @ViewBuilder
    private var friendRequestButton: some View {
        if FWBFeatures.friendRequests {
            if author.acceptsFriendRequests {
                Button {
                    toasts.show("Friend requests arrive with private chat.")
                } label: {
                    Label("Send friend request", systemImage: "person.badge.plus")
                }
                .buttonStyle(FWBPrimaryButtonStyle())
            } else {
                Text("\(author.name) isn't accepting friend requests from the forum.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var blockedNotice: some View {
        VStack(spacing: Theme.Spacing.md) {
            Text("You blocked this member.")
                .font(Theme.Typography.preview)
                .foregroundStyle(.secondary)

            Button {
                unblock()
            } label: {
                Label("Unblock", systemImage: "hand.raised.slash")
            }
            .buttonStyle(FWBSecondaryButtonStyle())
            .disabled(isWorking)
        }
    }

    // MARK: - Mutations

    private func block() {
        isWorking = true
        Task {
            do {
                try await APIClient.shared.block(userId: author.id)
                blocks.markBlocked(author.id)
                isWorking = false
                toasts.success("Blocked \(author.name).")
                dismiss()
            } catch {
                isWorking = false
                guard !isCancellationError(error) else { return }
                toasts.error(error.localizedDescription)
            }
        }
    }

    private func unblock() {
        isWorking = true
        Task {
            do {
                try await APIClient.shared.unblock(userId: author.id)
                blocks.markUnblocked(author.id)
                isWorking = false
                toasts.success("Unblocked \(author.name).")
            } catch {
                isWorking = false
                guard !isCancellationError(error) else { return }
                toasts.error(error.localizedDescription)
            }
        }
    }
}

// MARK: - Tap-to-open byline
//
// The reusable author row. Every place an author appears uses this, so the
// "tap a person to reach them" affordance can't be forgotten on a new surface —
// which matters more than usual when it is the *only* discovery path in the app.

struct AuthorByline: View {
    let author: ForumAuthor?
    var timestamp: Date?
    var wasEdited: Bool = false
    var avatarSize: CGFloat = 32
    var onTap: (ForumAuthor) -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            AvatarView(name: author?.name ?? "?", url: author?.avatarUrl, size: avatarSize)

            VStack(alignment: .leading, spacing: 1) {
                Text(author?.name ?? "Member")
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(.primary)

                if let timestamp {
                    Text(timestamp.formatted(.relative(presentation: .named))
                         + (wasEdited ? " · edited" : ""))
                        .font(Theme.Typography.micro)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // A tombstoned author has no profile to open.
            guard let author, author.isTappable else { return }
            onTap(author)
        }
        // A raw tap gesture on a content shape is invisible to VoiceOver: no button
        // trait, no action, nothing to activate. Since this byline is the *only* way
        // to reach a person from the forum (see the note at the top of this file),
        // that made every member profile in the app unreachable without sight. The
        // trait and the action are both gated on `isTappable` so a tombstoned author
        // is still announced as a name, not as a button that does nothing.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
        .accessibilityAddTraits(tappableAuthor == nil ? [] : .isButton)
        .accessibilityHint(tappableAuthor == nil ? "" : "Opens their profile.")
        .accessibilityAction {
            guard let tappableAuthor else { return }
            onTap(tappableAuthor)
        }
    }

    /// The author only when there is a profile behind them.
    private var tappableAuthor: ForumAuthor? {
        guard let author, author.isTappable else { return nil }
        return author
    }

    /// Name first, then when — the same order the row is drawn in.
    private var spokenLabel: String {
        var parts = [author?.name ?? "Member"]
        if let timestamp {
            parts.append(timestamp.formatted(.relative(presentation: .named)))
            if wasEdited { parts.append("edited") }
        }
        return parts.joined(separator: ", ")
    }
}

#Preview {
    AuthorProfileSheet(author: ForumAuthor(
        id: UUID().uuidString,
        displayName: "Alex Rivera",
        username: "alex",
        avatarUrl: nil,
        allowsFriendRequests: true,
        isDeleted: false))
    .environment(ToastCenter())
}
