import Foundation
import UIKit

// MARK: - Avatar upload
//
// `POST /api/auth/avatar` — multipart/form-data, field name `file`, answering
// the full `UserResponse` (fwb-server `AuthController.uploadAvatar`).
//
// # The contract, and what the client owes it
//
//  * **JPEG, PNG or HEIC only.** Anything else is a 400. This client always
//    sends JPEG, because it re-encodes anyway.
//  * **1 MB of image**, hard. (The route's body allowance is 10 MB, but that is
//    the multipart envelope; the handler measures the file.) A modern iPhone
//    photo is 3–8 MB, so uploading the picked bytes unchanged would fail for
//    almost every member — the downscale below is not an optimisation.
//  * The object lands at `avatars/<user>-<uuid>.<ext>` and **the previous object
//    is deleted**, so every upload is a new key and therefore a new URL.
//  * The response's `avatar_url` is a **1-hour presigned R2 URL** — there is no
//    public bucket (plan §1.5). It is re-minted on every `/me`, so it is *not*
//    a stable URL and needs no cache-busting; see `AvatarView`, which caches on
//    the object path so the re-minted signature doesn't re-download the same
//    bytes.
//
// **There is no remove-avatar route.** No `DELETE /api/auth/avatar`, and
// `UpdateProfileRequest` carries no avatar field — the only way `avatar_r2_key`
// returns to NULL is account deletion. So the UI offers "change", not "remove".

@MainActor
enum AvatarPreparer {

    /// The server's cap, mirrored so the member is stopped here rather than by a
    /// 413 after the bytes have crossed the network.
    static let maxBytes = 1_048_576

    /// Avatars are drawn in circles no larger than ~120pt. 1024² is already
    /// generous for @3x, and it keeps a re-encode comfortably inside the 1 MB cap
    /// without a second pass in the common case.
    static let maxDimension: CGFloat = 1024

    /// Centre-crop to a square, downscale to `maxDimension`, encode as JPEG under
    /// the byte cap.
    ///
    /// The crop is done here rather than at render time because the *stored*
    /// object is what every other surface reads: a 4:3 photo squeezed into a
    /// circle by `scaledToFill` looks right locally and wrong in every export,
    /// notification and future web view. Quality walks down only if the first
    /// encode is over cap — re-encoding is cheaper than an upload the server
    /// refuses.
    static func squareJPEG(from data: Data, maxDimension: CGFloat = maxDimension) -> Data? {
        guard let image = UIImage(data: data) else { return nil }

        // `size` is in orientation-corrected points, and `draw(in:)` applies the
        // orientation — which is why this works for a photo taken in portrait
        // without touching `cgImage` or `imageOrientation` by hand.
        let shortEdge = min(image.size.width, image.size.height)
        guard shortEdge > 0 else { return nil }
        let side = min(shortEdge, maxDimension)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let square = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            // Scale so the SHORT edge fills the square; the long edge overflows
            // equally on both sides, and that overflow is the crop.
            let scale = side / shortEdge
            let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (side - drawn.width) / 2,
                                  y: (side - drawn.height) / 2,
                                  width: drawn.width,
                                  height: drawn.height))
        }

        for quality in [CGFloat(0.9), 0.8, 0.7, 0.55, 0.4] {
            if let encoded = square.jpegData(compressionQuality: quality), encoded.count <= maxBytes {
                return encoded
            }
        }
        return square.jpegData(compressionQuality: 0.3)
    }
}

nonisolated enum AvatarError: LocalizedError {
    case unreadableImage

    var errorDescription: String? {
        switch self {
        case .unreadableImage: "We couldn't read that image. Try a different photo."
        }
    }
}
