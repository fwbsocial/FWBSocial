import SwiftUI

// MARK: - Post detail + comment thread
//
// The post, its reactions, and the whole comment thread — which the server hands
// back flat and unpaginated (`{ items, total }`), because a thread is read whole
// and paginating it would put a "load more" between a question and its answer.
//
// Every permission on this screen is server-resolved: `canEdit` (author only),
// `canDelete` (author or moderator), `canModerate` (pin/lock), and the channel's
// `canComment`. None of it is recomputed here.

struct PostDetailView: View {

    let postId: String
    let channel: Channel

    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var auth = AuthService.shared
    @State private var blocks = BlockStore.shared

    @State private var post: ForumPost?
    @State private var comments: [ForumComment] = []
    @State private var isLoading = false
    @State private var error: String?

    @State private var draft = ""
    @State private var replyingTo: ForumComment?
    @State private var editingComment: ForumComment?
    @State private var isSending = false

    @State private var isComposingEdit = false
    @State private var reportTarget: ReportTargetDescriptor?
    @State private var profileTarget: ForumAuthor?
    @State private var isConfirmingDelete = false
    @State private var pendingCommentDelete: ForumComment?

    @FocusState private var isComposerFocused: Bool

    private var visibleComments: [ForumComment] {
        comments.filteringBlocked(blocks)
    }

    /// Top-level comments, each followed by its replies. One nesting level only —
    /// the server re-parents deeper replies onto the top-level comment, so there
    /// is never a chain to walk.
    private var threaded: [(parent: ForumComment, replies: [ForumComment])] {
        let all = visibleComments
        let tops = all.filter { !$0.isReply }
        return tops.map { top in
            (top, all.filter { $0.parentCommentId == top.id })
        }
    }

    private var canComment: Bool {
        channel.mayComment && !(post?.locked ?? false) && !(post?.isRemoved ?? false)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                if let post {
                    postHeader(post)
                    Divider()
                    commentsSection
                } else if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if let error {
                    FormErrorText(message: error).padding()
                }
            }
            .padding()
        }
        .fwbDismissKeyboardOnTap()
        .navigationTitle("Thread")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if canComment { composer }
        }
        .toolbar {
            if let post {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        postMenu(post)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("thread.menu")
                }
            }
        }
        .task {
            await blocks.loadIfNeeded()
            await load()
        }
        .refreshable { await load() }
        .sheet(isPresented: $isComposingEdit) {
            if let post {
                PostComposerView(channel: channel, editing: post) { updated in
                    self.post = updated
                }
            }
        }
        .sheet(item: $profileTarget) { author in
            AuthorProfileSheet(author: author)
        }
        .fwbReportSheet($reportTarget)
        .confirmationDialog("Delete this post?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deletePost() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The thread's comments stay, attributed to their authors.")
        }
        .confirmationDialog(
            "Delete this comment?",
            isPresented: Binding(
                get: { pendingCommentDelete != nil },
                set: { if !$0 { pendingCommentDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let comment = pendingCommentDelete { deleteComment(comment) }
                pendingCommentDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingCommentDelete = nil }
        }
    }

    // MARK: - Post

    @ViewBuilder
    private func postHeader(_ post: ForumPost) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if post.pinned || post.locked || post.isRemoved {
                HStack(spacing: Theme.Spacing.sm) {
                    if post.pinned {
                        StatusBadge("Pinned", color: Theme.Colors.brand)
                    }
                    if post.locked {
                        StatusBadge("Locked", color: Theme.Colors.caution)
                    }
                    if post.isRemoved {
                        StatusBadge("Removed", color: Theme.Colors.danger)
                    }
                }
            }

            Text(post.displayTitle)
                .font(Theme.Typography.title)
                .foregroundStyle(.primary)

            AuthorByline(
                author: post.author,
                timestamp: post.timestamp,
                wasEdited: post.wasEdited,
                avatarSize: 36,
                onTap: { profileTarget = $0 })

            if post.isRemoved {
                // A removal is a status transition, not a delete, so the reason
                // is worth stating where the body used to be.
                Text(post.removalReason.map { "Removed by a moderator: \($0)" }
                     ?? "This post was removed by a moderator.")
                    .font(Theme.Typography.preview)
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                Text(post.displayBody)
                    .font(Theme.Typography.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }

            if !post.media.isEmpty {
                PostMediaView(media: post.media)
            }

            if post.locked {
                Label("This thread is locked. No new comments.",
                      systemImage: "lock.fill")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            ReactionControl(
                myReaction: post.myReaction,
                count: post.reactions,
                canReact: !post.isRemoved
            ) { reaction in
                if let reaction {
                    try await APIClient.shared.setPostReaction(id: post.id, reaction: reaction)
                } else {
                    try await APIClient.shared.clearPostReaction(id: post.id)
                }
            }
        }
    }

    @ViewBuilder
    private func postMenu(_ post: ForumPost) -> some View {
        if post.mayEdit && !post.locked && !post.isRemoved {
            Button {
                isComposingEdit = true
            } label: {
                Label("Edit", systemImage: "pencil")
            }
        }

        // Moderator tools. `canModerate` is the resolved channel role, so a
        // per-channel moderator gets these without being a global one.
        if post.mayModerate {
            Button {
                setPinned(!post.pinned)
            } label: {
                Label(post.pinned ? "Unpin" : "Pin", systemImage: post.pinned ? "pin.slash" : "pin")
            }
            Button {
                setLocked(!post.locked)
            } label: {
                Label(post.locked ? "Unlock" : "Lock", systemImage: post.locked ? "lock.open" : "lock")
            }
        }

        if post.author?.id != auth.user?.id {
            Button(role: .destructive) {
                reportTarget = ReportTargetDescriptor(
                    targetType: .post,
                    targetId: post.id,
                    subjectName: post.displayTitle,
                    blockableUserId: post.author?.id)
            } label: {
                Label("Report", systemImage: "flag")
            }
        }

        if post.mayDelete && !post.isRemoved {
            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Comments

    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text(visibleComments.isEmpty
                 ? "No comments yet"
                 : "\(visibleComments.count) comment\(visibleComments.count == 1 ? "" : "s")")
                .font(Theme.Typography.headline)
                .foregroundStyle(.primary)

            ForEach(threaded, id: \.parent.id) { group in
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    commentRow(group.parent)

                    ForEach(group.replies) { reply in
                        commentRow(reply)
                            .padding(.leading, Theme.Spacing.xxl)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func commentRow(_ comment: ForumComment) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            AuthorByline(
                author: comment.author,
                timestamp: comment.createdAt,
                wasEdited: comment.wasEdited,
                avatarSize: 28,
                onTap: { profileTarget = $0 })

            if comment.isRemoved {
                Text("This comment was removed.")
                    .font(Theme.Typography.preview)
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                Text(comment.displayBody)
                    .font(Theme.Typography.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }

            HStack(spacing: Theme.Spacing.lg) {
                ReactionControl(
                    myReaction: comment.myReaction,
                    count: comment.reactions,
                    canReact: !comment.isRemoved && channel.mayComment
                ) { reaction in
                    if let reaction {
                        try await APIClient.shared.setCommentReaction(id: comment.id, reaction: reaction)
                    } else {
                        try await APIClient.shared.clearCommentReaction(id: comment.id)
                    }
                }

                if canComment && !comment.isRemoved && !comment.isReply {
                    Button("Reply") {
                        replyingTo = comment
                        isComposerFocused = true
                    }
                    .font(Theme.Typography.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Colors.brand)
                }
                Spacer()
            }
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Colors.surface, in: Theme.roundedRect(Theme.Radius.chip))
        .contextMenu {
            if comment.mayEdit && !comment.isRemoved {
                Button {
                    editingComment = comment
                    draft = comment.displayBody
                    isComposerFocused = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }
            if comment.author?.id != auth.user?.id {
                Button(role: .destructive) {
                    reportTarget = ReportTargetDescriptor(
                        targetType: .comment,
                        targetId: comment.id,
                        subjectName: "a comment by \(comment.author?.name ?? "a member")",
                        blockableUserId: comment.author?.id)
                } label: {
                    Label("Report", systemImage: "flag")
                }
            }
            if comment.mayDelete && !comment.isRemoved {
                Button(role: .destructive) {
                    pendingCommentDelete = comment
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: Theme.Spacing.sm) {
            if let replyingTo {
                contextChip(
                    text: "Replying to \(replyingTo.author?.name ?? "a comment")",
                    clear: { self.replyingTo = nil })
            }
            if editingComment != nil {
                contextChip(text: "Editing your comment", clear: {
                    editingComment = nil
                    draft = ""
                })
            }

            HStack(spacing: Theme.Spacing.sm) {
                TextField("Add a comment", text: $draft, axis: .vertical)
                    .accessibilityIdentifier("thread.commentField")
                    .lineLimit(1...5)
                    .focused($isComposerFocused)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, 10)
                    .background(Theme.Colors.field, in: Capsule())

                Button {
                    sendComment()
                } label: {
                    Image(systemName: editingComment == nil ? "arrow.up.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(canSend ? Theme.Colors.brand : Color.secondary.opacity(0.5))
                }
                .disabled(!canSend)
                .accessibilityIdentifier("thread.send")
                .accessibilityLabel(editingComment == nil ? "Send comment" : "Save comment")
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .background(.bar)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    private func contextChip(text: String, clear: @escaping () -> Void) -> some View {
        HStack {
            Text(text)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                clear()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Data

    private func load() async {
        isLoading = true
        error = nil
        do {
            async let postTask = APIClient.shared.post(id: postId)
            async let commentsTask = APIClient.shared.comments(postId: postId)
            post = try await postTask
            comments = try await commentsTask.items
        } catch {
            guard !isCancellationError(error) else { isLoading = false; return }
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func sendComment() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        fwbDismissKeyboard()
        isSending = true

        Task {
            do {
                if let editing = editingComment {
                    let updated = try await APIClient.shared.updateComment(id: editing.id, body: text)
                    if let idx = comments.firstIndex(where: { $0.id == updated.id }) {
                        comments[idx] = updated
                    }
                    editingComment = nil
                } else {
                    let created = try await APIClient.shared.createComment(
                        postId: postId, body: text, parentCommentId: replyingTo?.id)
                    comments.append(created)
                    replyingTo = nil
                    // The count lives on the post, which the server bumped —
                    // refetch it rather than guessing.
                    post = try? await APIClient.shared.post(id: postId)
                }
                draft = ""
                isSending = false
            } catch {
                isSending = false
                guard !isCancellationError(error) else { return }
                toasts.error(error.localizedDescription)
            }
        }
    }

    private func deletePost() {
        Task {
            do {
                try await APIClient.shared.deletePost(id: postId)
                toasts.success("Post deleted.")
                dismiss()
            } catch {
                guard !isCancellationError(error) else { return }
                toasts.error(error.localizedDescription)
            }
        }
    }

    private func deleteComment(_ comment: ForumComment) {
        Task {
            do {
                try await APIClient.shared.deleteComment(id: comment.id)
                comments.removeAll { $0.id == comment.id }
                toasts.success("Comment deleted.")
            } catch {
                guard !isCancellationError(error) else { return }
                toasts.error(error.localizedDescription)
            }
        }
    }

    private func setPinned(_ pinned: Bool) {
        Task {
            do {
                post = try await APIClient.shared.setPostPinned(id: postId, pinned: pinned)
                toasts.success(pinned ? "Pinned." : "Unpinned.")
            } catch {
                guard !isCancellationError(error) else { return }
                toasts.error(error.localizedDescription)
            }
        }
    }

    private func setLocked(_ locked: Bool) {
        Task {
            do {
                post = try await APIClient.shared.setPostLocked(id: postId, locked: locked)
                toasts.success(locked ? "Thread locked." : "Thread unlocked.")
            } catch {
                guard !isCancellationError(error) else { return }
                toasts.error(error.localizedDescription)
            }
        }
    }
}
