import AVFoundation
import Foundation
import UIKit

// MARK: - Forum post media
//
// Owner decision: photos AND video, **4 photos OR 1 video, never both**. Mirrors
// fwb-server's `PostMediaController` (commit 95812c9).
//
// # Two upload shapes, and why the client has to care
//
// **Photos go THROUGH the server** (multipart), because that is the only way the
// server can generate a thumbnail — it cannot resize bytes it never sees.
//
// **Video goes STRAIGHT to R2** on a presigned PUT: 100 MB through Vapor would be
// 100 MB of process memory on the same 1 GB box that holds every live chat
// WebSocket. The client supplies the poster frame, because v1 has no transcode
// pipeline and the server never decodes video.
//
// So a video is three round trips — ticket, two direct PUTs, attach — and the ticket
// exists so an over-cap upload is refused *before* 100 MB crosses the network rather
// than after.

nonisolated struct PostMediaDTO: Decodable, Sendable, Identifiable, Equatable {
    let id: UUID
    let postId: UUID
    /// `photo` | `video`.
    let kind: String
    /// A 1-hour signed URL. Nil when R2 is unconfigured, or when the object is
    /// gone — render the placeholder rather than an empty frame.
    let url: String?
    /// **Nil is normal, not an error.** The server keeps a thumbnail only when it
    /// is actually smaller than the original (server commit 95812c9); a small photo
    /// has none, and the full image IS the thumbnail. Falling back to `url` is the
    /// correct handling, and treating nil as failure would blank exactly the
    /// cheapest images.
    let thumbnailUrl: String?
    let width: Int?
    let height: Int?
    let durationS: Double?
    let byteSize: Int?
    let contentType: String?
    let ordering: Int

    var isVideo: Bool { kind == "video" }

    /// What to show in a grid cell. Prefers the thumbnail, falls back to the full
    /// object, and yields nil only when there is genuinely nothing to draw.
    var previewUrl: String? { thumbnailUrl ?? url }

    var aspectRatio: CGFloat? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return CGFloat(width) / CGFloat(height)
    }
}

nonisolated struct VideoUploadTicketRequest: Encodable, Sendable {
    let contentType: String
    let byteSize: Int
    let durationS: Double
    let width: Int?
    let height: Int?
}

nonisolated struct VideoUploadTicketResponse: Decodable, Sendable {
    let objectKey: String
    let uploadUrl: String
    let posterUploadUrl: String
    let posterObjectKey: String
    let expiresInSeconds: Int
}

nonisolated struct AttachVideoRequest: Encodable, Sendable {
    let objectKey: String
    let posterObjectKey: String
    let contentType: String
    let byteSize: Int
    let durationS: Double
    let width: Int?
    let height: Int?
}

// MARK: - Limits
//
// Mirrors `PostMediaLimits`. Validated client-side too — not because the server
// can't be trusted, but because a member who picks a 4-minute video should learn
// that before uploading 90 MB of it.

nonisolated enum PostMediaLimits {
    static let maxPhotos = 4
    static let maxVideos = 1
    static let maxPhotoBytes = 10 * 1024 * 1024
    static let maxVideoBytes = 100 * 1024 * 1024
    /// Client-enforced. The server cannot verify duration without decoding video,
    /// which v1 explicitly does not do — the byte cap is its enforceable backstop.
    static let maxVideoSeconds: Double = 120
    static let photoContentTypes: Set<String> = ["image/jpeg", "image/png", "image/heic", "image/webp"]
    static let videoContentTypes: Set<String> = ["video/mp4", "video/quicktime"]
}

nonisolated enum PostMediaError: LocalizedError {
    case tooManyPhotos
    case videoTooLong(Double)
    case videoTooLarge(Int)
    case unsupportedVideoType
    case photosAndVideo
    case posterFrameFailed

    var errorDescription: String? {
        switch self {
        case .tooManyPhotos:
            return "You can add up to \(PostMediaLimits.maxPhotos) photos."
        case .videoTooLong(let seconds):
            return "That video is \(Int(seconds.rounded())) seconds. Videos need to be under \(Int(PostMediaLimits.maxVideoSeconds))."
        case .videoTooLarge(let bytes):
            return "That video is \(bytes / 1_048_576) MB. Videos need to be under \(PostMediaLimits.maxVideoBytes / 1_048_576) MB."
        case .unsupportedVideoType:
            return "That video format isn't supported. Try an MP4 or a QuickTime file."
        case .photosAndVideo:
            return "A post can have photos or one video, not both."
        case .posterFrameFailed:
            return "We couldn't read a still from that video."
        }
    }
}

// MARK: - API

extension APIClient {

    /// `GET /api/posts/:id/media` — fresh 1-hour signed URLs.
    ///
    /// The feed and the detail route already embed `media`, so this is for
    /// REFRESHING expired URLs on a screen left open, not for the initial load.
    func postMedia(postId: String) async throws -> [PostMediaDTO] {
        try await get("/api/posts/\(postId)/media")
    }

    /// `POST /api/posts/:id/media/photo` — multipart, one photo per call.
    @discardableResult
    func uploadPostPhoto(postId: String, jpeg: Data) async throws -> PostMediaDTO {
        try await upload(
            "/api/posts/\(postId)/media/photo",
            fileData: jpeg,
            fileName: "photo.jpg",
            mimeType: "image/jpeg"
        )
    }

    func videoTicket(postId: String, body: VideoUploadTicketRequest) async throws -> VideoUploadTicketResponse {
        try await post("/api/posts/\(postId)/media/video-ticket", body: body)
    }

    @discardableResult
    func attachVideo(postId: String, body: AttachVideoRequest) async throws -> PostMediaDTO {
        try await post("/api/posts/\(postId)/media/video", body: body)
    }

    /// Author-or-moderator, enforced server-side.
    func deletePostMedia(postId: String, mediaId: UUID) async throws {
        try await delete("/api/posts/\(postId)/media/\(mediaId.uuidString)")
    }
}

// MARK: - Client-side preparation
//
// The compression patterns the chat media path already uses, applied to the forum's
// caps.

@MainActor
enum PostMediaPreparer {

    /// Downscale and JPEG-encode so a 12 MP HEIC does not arrive as 8 MB.
    ///
    /// Two passes: bound the long edge first (which is most of the saving), then
    /// walk quality down only if the result is still over the cap. Re-encoding a
    /// second time at a lower quality is cheaper than uploading, being refused, and
    /// making the member choose again.
    static func compressPhoto(_ data: Data, maxDimension: CGFloat = 2048) -> Data? {
        guard let image = UIImage(data: data) else { return nil }

        let longEdge = max(image.size.width, image.size.height)
        let scaled: UIImage
        if longEdge > maxDimension {
            let scale = maxDimension / longEdge
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        } else {
            scaled = image
        }

        for quality in [CGFloat(0.85), 0.7, 0.55, 0.4] {
            if let encoded = scaled.jpegData(compressionQuality: quality),
               encoded.count <= PostMediaLimits.maxPhotoBytes {
                return encoded
            }
        }
        return scaled.jpegData(compressionQuality: 0.3)
    }

    /// Duration, pixel size and a poster frame — everything the ticket and the
    /// attach call need, read once.
    ///
    /// The poster is the client's job because the server never decodes video. A
    /// video with no poster would render as a black rectangle in the feed, which is
    /// indistinguishable from a broken upload.
    static func inspectVideo(at url: URL) async throws -> (duration: Double, size: CGSize?, poster: Data) {
        let asset = AVURLAsset(url: url)
        let duration = try await CVDouble(asset)

        guard duration <= PostMediaLimits.maxVideoSeconds else {
            throw PostMediaError.videoTooLong(duration)
        }

        var pixelSize: CGSize?
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let natural = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            // `naturalSize` ignores rotation, so a portrait clip reports landscape
            // and the cell lays out sideways. Applying the transform to a RECT (not
            // a size) is what carries the rotation; `abs` because a flip transform
            // yields negative extents.
            let oriented = CGRect(origin: .zero, size: natural).applying(transform)
            pixelSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        // A frame at exactly 0 is often black on a fade-in; a moment in is a better
        // still, but clamp so a very short clip still yields something.
        let frameTime = CMTime(seconds: min(0.5, duration / 2), preferredTimescale: 600)
        let cgImage = try await generator.image(at: frameTime).image

        guard let poster = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.8) else {
            throw PostMediaError.posterFrameFailed
        }
        return (duration, pixelSize, poster)
    }

    private static func CVDouble(_ asset: AVURLAsset) async throws -> Double {
        CMTimeGetSeconds(try await asset.load(.duration))
    }

    /// PUT to a presigned R2 URL. No bearer token — R2 rejects the extra header on a
    /// signed URL, and the bytes deliberately never transit the API server.
    static func putToPresignedURL(_ urlString: String, data: Data, contentType: String) async throws {
        guard let url = URL(string: urlString) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        let (_, response) = try await FWBHTTP.session.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0, message: "Upload failed")
        }
    }
}
