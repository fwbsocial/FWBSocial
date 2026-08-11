import SwiftUI

// MARK: - Full-screen media viewer
//
// Cove's `ConversationMediaViewer` is 923 lines because it carries a pager, video
// playback, a gallery grid and a share sheet. Photos are what v1 sends (owner
// directive: "media sharing (photos; viewer)"), so this is the photo viewer and
// nothing else.
//
// **The decrypt seam is unchanged and that is the whole point.** PLAN.md §5.2 keeps
// both media files "untouched" under E2EE precisely because
// `ChatService.decryptMedia(for:)` is already correct: the R2 object is ciphertext,
// and the key that opens it is the same per-message key that opened the body. There
// was nothing to swap out — which is the saving the E2EE decision bought.

struct ChatMediaViewer: View {
    let message: ChatMessage

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var failure: String?
    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in scale = max(1, committedScale * value.magnification) }
                            .onEnded { _ in committedScale = scale }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(Theme.Motion.bubble) {
                            scale = scale > 1 ? 1 : 2.5
                            committedScale = scale
                        }
                    }
            } else if let failure {
                VStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 40, weight: .light))
                    Text(failure)
                        .font(Theme.Typography.preview)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white.opacity(0.75))
                .padding(Theme.Spacing.xxl)
            } else {
                ProgressView().tint(.white)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.8), .black.opacity(0.35))
            }
            .padding(Theme.Spacing.lg)
            .accessibilityIdentifier("chat.media.close")
        }
        .statusBarHidden()
        .task {
            do {
                let data = try await ChatService.shared.decryptMedia(for: message)
                guard let decoded = UIImage(data: data) else {
                    failure = "That photo couldn't be opened."
                    return
                }
                image = decoded
            } catch ChatCryptoError.noKeyForMessage {
                // The honest distinction, again: this device has no key for this
                // message, which for history that predates it is expected, not
                // broken.
                failure = "This device doesn't have the key for that photo."
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? "That photo couldn't be loaded."
            }
        }
    }
}
