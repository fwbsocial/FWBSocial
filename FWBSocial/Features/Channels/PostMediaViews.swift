import AVKit
import SwiftUI

// MARK: - Post media rendering
//
// A post carries up to 4 photos OR one video, so there are exactly two layouts and
// no combinatorial grid logic to get wrong.
//
// Thumbnails load lazily via `AsyncImage`, which is deliberate on a feed: a channel
// page can hold twenty posts, and eagerly fetching every full-size object would cost
// more bandwidth than the text it decorates.

struct PostMediaView: View {
    let media: [PostMediaDTO]
    /// Feeds get a bounded height; a detail screen lets the media breathe.
    var isCompact = false

    @State private var lightboxIndex: Int?

    private var photos: [PostMediaDTO] { media.filter { !$0.isVideo }.sorted { $0.ordering < $1.ordering } }
    private var video: PostMediaDTO? { media.first(where: \.isVideo) }

    var body: some View {
        if let video {
            PostVideoPlayer(media: video, isCompact: isCompact)
        } else if !photos.isEmpty {
            grid
                .fullScreenCover(item: $lightboxIndex) { index in
                    PhotoLightbox(photos: photos, startIndex: index)
                }
        }
    }

    // MARK: Photo grid

    @ViewBuilder
    private var grid: some View {
        switch photos.count {
        case 1:
            cell(photos[0], index: 0)
                // A single photo keeps its own shape rather than being cropped to a
                // square — the framing was the poster's decision.
                .aspectRatio(photos[0].aspectRatio ?? 4 / 3, contentMode: .fit)
                .frame(maxHeight: isCompact ? 260 : 460)
        case 2:
            HStack(spacing: 2) { squares(photos) }
                .frame(height: isCompact ? 160 : 220)
        case 3:
            // Two-up: one tall on the left, two stacked on the right. Three equal
            // columns would make each one a letterbox slot too thin to read.
            HStack(spacing: 2) {
                cell(photos[0], index: 0).frame(maxWidth: .infinity)
                VStack(spacing: 2) {
                    cell(photos[1], index: 1)
                    cell(photos[2], index: 2)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: isCompact ? 200 : 280)
        default:
            VStack(spacing: 2) {
                HStack(spacing: 2) { squares(Array(photos.prefix(2))) }
                HStack(spacing: 2) { squares(Array(photos.dropFirst(2).prefix(2))) }
            }
            .frame(height: isCompact ? 240 : 320)
        }
    }

    @ViewBuilder
    private func squares(_ items: [PostMediaDTO]) -> some View {
        ForEach(items) { item in
            cell(item, index: photos.firstIndex(of: item) ?? 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func cell(_ item: PostMediaDTO, index: Int) -> some View {
        PostMediaThumbnail(media: item)
            .contentShape(Rectangle())
            .onTapGesture { lightboxIndex = index }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Photo \(index + 1) of \(photos.count)")
    }
}

// MARK: - Thumbnail

/// One image cell.
///
/// `previewUrl` is thumbnail-then-original, because **a nil thumbnail is normal**:
/// the server keeps one only when it is actually smaller than the source, so a small
/// photo has none and the original IS the thumbnail. Treating nil as failure would
/// blank exactly the cheapest images.
struct PostMediaThumbnail: View {
    let media: PostMediaDTO

    // `scaledToFill` deliberately reports a size LARGER than the proposal, and
    // `.clipped()` clips a view to its own reported size — so with nothing
    // establishing a definite box between them, a fill-scaled image does not get
    // clipped to its cell at all. It escapes, and in a `List` row it paints over
    // whatever is beside and above it: a three-photo post in a channel feed drew
    // its right-hand column across the post's own title. The detail screen was
    // unaffected only because its cells happen to be handed definite sizes.
    //
    // `Color.clear` accepts exactly the size it is offered, so the overlay it
    // carries has a real box, and the clip finally has bounds that mean something.
    var body: some View {
        Color.clear
            .overlay { content }
            .clipped()
            .fwbCorner(Theme.Radius.chip)
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if let urlString = media.previewUrl, let url = URL(string: urlString) {
                AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.18))) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholder(systemImage: "photo.badge.exclamationmark")
                    case .empty:
                        placeholder(systemImage: nil)
                    @unknown default:
                        placeholder(systemImage: nil)
                    }
                }
            } else {
                // No signed URL at all — R2 unconfigured, or the object is gone.
                placeholder(systemImage: "photo")
            }
        }
    }

    @ViewBuilder
    private func placeholder(systemImage: String?) -> some View {
        ZStack {
            Theme.Colors.surface
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            } else {
                ProgressView()
            }
        }
        // The placeholder stands in for a photo, so it is a filled box with a
        // glyph on it — the glyph has to be dark once the box turns white.
        .fwbThemedContainer()
    }
}

// MARK: - Video

/// Inline playback, with a tap to go full screen.
///
/// Starts on the POSTER, not on an `AVPlayer`: a feed with several video posts would
/// otherwise spin up a player per row, and each one holds a decoder. The player is
/// created on first tap and torn down when the view goes away.
struct PostVideoPlayer: View {
    let media: PostMediaDTO
    var isCompact = false

    @State private var player: AVPlayer?
    @State private var isPresentingFullScreen = false

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
                    .onDisappear { player.pause() }
            } else {
                PostMediaThumbnail(media: media)
                Button {
                    start()
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.white, .black.opacity(0.35))
                        .shadow(radius: 6)
                }
                .accessibilityLabel("Play video")
                .accessibilityIdentifier("post.video.play")
            }
        }
        .aspectRatio(media.aspectRatio ?? 16 / 9, contentMode: .fit)
        .frame(maxHeight: isCompact ? 260 : 460)
        .fwbCorner(Theme.Radius.chip)
        .overlay(alignment: .bottomTrailing) {
            if let duration = media.durationS {
                Text(Self.timestamp(duration))
                    .font(Theme.Typography.micro.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(Theme.Spacing.sm)
            }
        }
        .overlay(alignment: .topTrailing) {
            if player != nil {
                Button {
                    isPresentingFullScreen = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .padding(8)
                        .background(.black.opacity(0.45), in: Circle())
                        .foregroundStyle(.white)
                }
                .padding(Theme.Spacing.sm)
                .accessibilityLabel("Full screen")
            }
        }
        .fullScreenCover(isPresented: $isPresentingFullScreen) {
            FullScreenVideo(player: player)
        }
    }

    private func start() {
        guard let urlString = media.url, let url = URL(string: urlString) else { return }
        let player = AVPlayer(url: url)
        self.player = player
        player.play()
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct FullScreenVideo: View {
    let player: AVPlayer?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear { player.play() }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    // The circle behind the glyph stays a literal black — it is a
                    // scrim over the video frame, not a themed surface.
                    .foregroundStyle(Color.primary.opacity(0.85), .black.opacity(0.35))
            }
            .padding(Theme.Spacing.lg)
            // Icon-only and unlabelled, this was announced as "button" — the only way
            // out of full-screen playback had no name.
            .accessibilityLabel("Close")
        }
        // The backdrop is an imposed black whatever the member's appearance setting
        // is, so the chrome drawn on it must be read in dark terms. Saying that once
        // here is what lets `.primary` resolve to the right thing above.
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
    }
}

// MARK: - Photo lightbox

private struct PhotoLightbox: View {
    let photos: [PostMediaDTO]
    let startIndex: Int

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Int = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $selection) {
                ForEach(Array(photos.enumerated()), id: \.offset) { index, photo in
                    // The FULL object here, not the thumbnail — this is the one
                    // place the original is worth its bytes.
                    if let urlString = photo.url, let url = URL(string: urlString) {
                        LightboxPage(url: url)
                            .tag(index)
                    }
                }
            }
            .tabViewStyle(.page)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    // The circle behind the glyph stays a literal black — it is a
                    // scrim over the photo, not a themed surface.
                    .foregroundStyle(Color.primary.opacity(0.85), .black.opacity(0.35))
            }
            .padding(Theme.Spacing.lg)
            .accessibilityIdentifier("post.photo.close")
            // The identifier is for the test runner and is never spoken; without a
            // label the only way out of the lightbox was announced as "button".
            .accessibilityLabel("Close")
        }
        // The backdrop is an imposed black whatever the member's appearance setting
        // is, so the chrome on top of it must be read in dark terms — including the
        // page dots, which in light mode resolved to a near-black on near-black and
        // gave no hint that there were more photos to swipe to.
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .task { selection = startIndex }
    }
}

/// One page of the lightbox.
///
/// Its own view, rather than an inline `AsyncImage`, so each page can own a retry.
/// `AsyncImage` has no reload call — the only way to re-run a fetch is to hand the
/// view a new identity — and a token shared across the pager would tear down and
/// refetch every other photo along with the one that failed.
private struct LightboxPage: View {
    let url: URL

    @State private var attempt = 0

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.18))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit()
            case .failure:
                // The old two-branch form had no failure arm at all, so a dropped
                // connection left the placeholder spinner turning forever: the
                // lightbox read as hung rather than as a download that failed, and
                // there was nothing to press.
                VStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 40, weight: .light))
                    Text("That photo couldn't be loaded.")
                        .font(Theme.Typography.preview)
                        .multilineTextAlignment(.center)
                    Button("Try again") { attempt += 1 }
                        .buttonStyle(FWBSecondaryButtonStyle())
                        .frame(maxWidth: 240)
                        .padding(.top, Theme.Spacing.sm)
                }
                .foregroundStyle(.secondary)
                .padding(Theme.Spacing.xxl)
            case .empty:
                ProgressView().tint(Color.primary)
            @unknown default:
                ProgressView().tint(Color.primary)
            }
        }
        .id(attempt)
    }
}

// `Int` needs to be `Identifiable` for `fullScreenCover(item:)`. Scoped to this file
// so it cannot leak a surprising conformance into the rest of the app.
extension Int: @retroactive Identifiable {
    public var id: Int { self }
}
