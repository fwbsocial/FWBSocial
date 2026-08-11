import SwiftUI

// MARK: - Channel feed
//
// One channel's posts: pinned first, then most-recent activity. **That ordering
// is the server's** and this view must not re-sort — the feed is paginated, and
// a client-side sort would only order the page it can see, drifting the pinned
// block out of place as soon as page two arrives.
//
// The compose affordance follows `channel.canPost`, which is the resolved role,
// not the channel's default. A comment-only channel simply has no compose
// button — better than offering one that 403s with an explanation.

struct ChannelFeedView: View {

    let channel: Channel

    @Environment(ToastCenter.self) private var toasts
    @State private var blocks = BlockStore.shared

    @State private var loader = PaginatedLoader<ForumPost>(per: 20)
    @State private var current: Channel
    @State private var isComposing = false
    @State private var reportTarget: ReportTargetDescriptor?
    @State private var profileTarget: ForumAuthor?
    @State private var hasLoaded = false

    init(channel: Channel) {
        self.channel = channel
        _current = State(initialValue: channel)
    }

    /// Blocked authors are filtered here, at render time rather than at fetch
    /// time, so an unblock brings their posts back without a refetch. The server
    /// does not do this for us — `Modules/Forum/` has no block join.
    private var visiblePosts: [ForumPost] {
        loader.items.filteringBlocked(blocks)
    }

    private var pinned: [ForumPost] { visiblePosts.filter(\.pinned) }
    private var unpinned: [ForumPost] { visiblePosts.filter { !$0.pinned } }

    var body: some View {
        List {
            // Only over content. With an empty feed the failure takes the whole
            // surface below, where it can carry a Try again.
            if let error = loader.error, !visiblePosts.isEmpty {
                Section { InlineErrorRow(message: error) { Task { await reload() } } }
            }

            if !pinned.isEmpty {
                Section {
                    ForEach(pinned) { post in row(post) }
                } header: {
                    Label("Pinned", systemImage: "pin.fill")
                }
            }

            Section {
                ForEach(unpinned) { post in
                    row(post)
                        .task { await loader.loadMoreIfNeeded(current: post, fetch) }
                }

                if loader.isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            }

            if visiblePosts.isEmpty && !loader.isLoading && hasLoaded {
                Section {
                    if let failure = loader.failure {
                        // "Start the first thread" over a failed fetch invites the
                        // member to write a post into a channel the app cannot
                        // currently read — and the composer would fail too.
                        ErrorStateView(error: failure) { Task { await reload() } }
                            .listRowBackground(Color.clear)
                    } else {
                        EmptyStateView(
                            icon: "text.bubble",
                            title: current.mayPost ? "Start the first thread" : "Nothing here yet",
                            message: current.mayPost
                                ? "Be the first to post in \(current.displayName)."
                                : "Posts in this channel will show up here.",
                            actionTitle: current.mayPost ? "New post" : nil,
                            action: current.mayPost ? { isComposing = true } : nil)
                        .listRowBackground(Color.clear)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(current.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        toggleMute()
                    } label: {
                        Label(current.isMuted ? "Unmute channel" : "Mute channel",
                              systemImage: current.isMuted ? "bell" : "bell.slash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Channel actions")
            }

        }
        // Only where the resolved role allows it — a button that appears and then
        // 403s is worse than no button.
        .floatingAction(
            isVisible: current.mayPost && !current.archived,
            systemImage: "square.and.pencil",
            label: "New post"
        ) { isComposing = true }
        .task {
            guard !hasLoaded else { return }
            await blocks.loadIfNeeded()
            await loader.loadFirst(fetch)
            hasLoaded = true
        }
        .refreshable { await loader.loadFirst(fetch) }
        .sheet(isPresented: $isComposing) {
            PostComposerView(channel: current) { _ in
                Task { await loader.loadFirst(fetch) }
            }
        }
        .sheet(item: $profileTarget) { author in
            AuthorProfileSheet(author: author)
        }
        .fwbReportSheet($reportTarget)
    }

    // MARK: - Row

    @ViewBuilder
    private func row(_ post: ForumPost) -> some View {
        ZStack {
            // The label of a NavigationLink swallows taps on controls inside it
            // (house rule: a Button inside a NavigationLink label eats the tap),
            // so the link is a hidden sibling behind the content rather than a
            // wrapper around it. That keeps the byline tappable.
            NavigationLink {
                PostDetailView(postId: post.id, channel: current)
            } label: { EmptyView() }
            .opacity(0)

            PostRow(
                post: post,
                onAuthorTap: { profileTarget = $0 },
                onReport: {
                    reportTarget = ReportTargetDescriptor(
                        targetType: .post,
                        targetId: post.id,
                        subjectName: post.displayTitle,
                        blockableUserId: post.author?.id)
                })
        }
    }

    // MARK: - Data

    /// What both the error state's "Try again" and pull-to-refresh do.
    private func reload() async {
        await blocks.loadIfNeeded()
        await loader.loadFirst(fetch)
        hasLoaded = true
    }

    private var fetch: PaginatedLoader<ForumPost>.PageFetcher {
        let slug = current.slug
        return { page, per in
            try await APIClient.shared.channelPosts(slug: slug, page: page, per: per)
        }
    }

    private func toggleMute() {
        let target = !current.isMuted
        Task {
            do {
                let updated = try await APIClient.shared.setChannelMuted(slug: current.slug, muted: target)
                current = updated
                toasts.success(target ? "Muted \(current.displayName)." : "Unmuted \(current.displayName).")
            } catch {
                guard !isCancellationError(error) else { return }
                toasts.error(error.fwbMessage)
            }
        }
    }
}

// MARK: - Post row

struct PostRow: View {
    let post: ForumPost
    var onAuthorTap: (ForumAuthor) -> Void
    var onReport: () -> Void

    @State private var auth = AuthService.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isMine: Bool { post.author?.id == auth.user?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            AuthorByline(
                author: post.author,
                timestamp: post.timestamp,
                wasEdited: post.wasEdited,
                onTap: onAuthorTap)

            HStack(spacing: 6) {
                // Pinned and locked are states nothing else in the row states, so
                // they are labelled rather than left as silent decoration.
                if post.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.brand)
                        .accessibilityLabel("Pinned")
                }
                if post.locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Locked")
                }
                Text(post.displayTitle)
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(.primary)
                    // Two lines is enough for a feed title at default sizes and
                    // clips a wrapped one at accessibility sizes, where a title is
                    // routinely four or five. The feed can afford the height; a
                    // member who cannot read the title cannot choose the thread.
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            }

            if !post.displayBody.isEmpty {
                Text(post.displayBody)
                    .font(Theme.Typography.preview)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            // Batched onto the feed response, so a grid costs no extra request.
            // Compact: a feed row should not become a full-bleed photo essay.
            if !post.media.isEmpty {
                PostMediaView(media: post.media, isCompact: true)
            }

            HStack(spacing: Theme.Spacing.lg) {
                Label("\(post.comments)", systemImage: "bubble.right")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)

                if post.reactions > 0 {
                    Label("\(post.reactions)", systemImage: "hand.thumbsup")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .contextMenu {
            if !isMine {
                Button(role: .destructive, action: onReport) {
                    Label("Report", systemImage: "flag")
                }
            }
        }
    }
}
