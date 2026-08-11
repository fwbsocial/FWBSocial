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

    var body: some View {
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
        .clipped()
        .fwbCorner(Theme.Radius.chip)
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
                    .foregroundStyle(.white.opacity(0.85), .black.opacity(0.35))
            }
            .padding(Theme.Spacing.lg)
        }
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
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            ProgressView().tint(.white)
                        }
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
                    .foregroundStyle(.white.opacity(0.85), .black.opacity(0.35))
            }
            .padding(Theme.Spacing.lg)
            .accessibilityIdentifier("post.photo.close")
        }
        .statusBarHidden()
        .task { selection = startIndex }
    }
}

// `Int` needs to be `Identifiable` for `fullScreenCover(item:)`. Scoped to this file
// so it cannot leak a surprising conformance into the rest of the app.
extension Int: @retroactive Identifiable {
    public var id: Int { self }
}
