import AVFoundation
import PhotosUI
import SwiftUI

// MARK: - Post composer
//
// Text-first, now with media: **up to 4 photos OR one video, never both** (owner
// decision, enforced server-side and validated here too).
//
// # Media is attached AFTER the post exists
//
// Every media route is `/api/posts/:id/media/*`, so there is no post id to attach to
// until the post is created. That ordering is the server's, and it is the right one
// — an upload that failed would otherwise strand bytes belonging to no post — but it
// means a partial failure is possible: the post lands, a photo does not. The
// composer reports exactly that rather than pretending the whole thing failed, since
// the words are already published and saying "couldn't post" would be a lie that
// makes people write it twice.
//
// Doubles as the edit composer. Editing is **author-only server-side** — a
// moderator can remove a post but cannot rewrite it, because editing someone's
// words under their name is a different power from taking them down.

struct PostComposerView: View {

    let channel: Channel
    /// Non-nil when editing rather than creating.
    var editing: ForumPost?
    var onSaved: (ForumPost) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts

    @State private var title = ""
    @State private var body_ = ""
    @State private var isSaving = false
    @State private var error: String?

    // Media. `photoItems` and `videoItem` are mutually exclusive by construction:
    // picking either clears the other, which is how "4 photos OR 1 video" stays
    // true without a validation error the member has to read.
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var videoItem: PhotosPickerItem?
    @State private var photoPreviews: [UIImage] = []
    @State private var videoPreview: UIImage?
    @State private var videoDuration: Double?
    @State private var mediaProgress: String?

    @FocusState private var focus: Field?
    private enum Field { case title, body }

    /// Mirrors the server's limits (`PostController.maxTitle` / `maxBody`) so the
    /// member is stopped by the field rather than by a 400.
    private let maxTitle = 200
    private let maxBody = 20_000

    private var isEditing: Bool { editing != nil }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && title.count <= maxTitle
        && body_.count <= maxBody
        && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                        .accessibilityIdentifier("composer.title")
                        .focused($focus, equals: .title)
                        .submitLabel(.next)
                        .onSubmit { focus = .body }
                } footer: {
                    if title.count > maxTitle {
                        Text("\(title.count) / \(maxTitle)")
                            .foregroundStyle(Theme.Colors.danger)
                    }
                }

                Section {
                    TextField("What's on your mind?", text: $body_, axis: .vertical)
                        .accessibilityIdentifier("composer.body")
                        .lineLimit(8...20)
                        .focused($focus, equals: .body)
                } header: {
                    Text("Post")
                } footer: {
                    if body_.count > maxBody {
                        Text("\(body_.count) / \(maxBody)")
                            .foregroundStyle(Theme.Colors.danger)
                    } else {
                        Text("Posting to \(channel.displayName). Everyone vetted can read this.")
                    }
                }

                mediaSection

                if let error {
                    Section { FormErrorText(message: error) }
                }
            }
            // Background layer, never on the Form itself.
            .fwbDismissKeyboardOnTap()
            .navigationTitle(isEditing ? "Edit post" : "New post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Post") { save() }
                        .accessibilityIdentifier("composer.submit")
                        .disabled(!canSave)
                }
            }
            .overlay {
                if isSaving {
                    VStack(spacing: Theme.Spacing.sm) {
                        ProgressView().controlSize(.large)
                        if let mediaProgress {
                            Text(mediaProgress)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { photoPreviews = []; return }
                videoItem = nil; videoPreview = nil; videoDuration = nil
                Task { await loadPhotoPreviews(items) }
            }
            .onChange(of: videoItem) { _, item in
                guard let item else { videoPreview = nil; videoDuration = nil; return }
                photoItems = []; photoPreviews = []
                Task { await loadVideoPreview(item) }
            }
            .onAppear {
                if let editing {
                    title = editing.title ?? ""
                    body_ = editing.body ?? ""
                }
                focus = .title
            }
        }
    }

    private func save() {
        // House rule: dismiss the keyboard as the first thing submit does, or it
        // survives the dismissal and sits over the next screen.
        fwbDismissKeyboard()
        isSaving = true
        error = nil

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBody = body_.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            do {
                let saved: ForumPost
                if let editing {
                    saved = try await APIClient.shared.updatePost(
                        id: editing.id, title: cleanTitle, body: cleanBody)
                } else {
                    saved = try await APIClient.shared.createPost(
                        slug: channel.slug, title: cleanTitle, body: cleanBody)
                }
                // The post exists now, so media can be attached to it.
                let mediaFailure = isEditing ? nil : await attachMedia(to: saved)
                mediaProgress = nil
                isSaving = false

                if let mediaFailure {
                    // The words are already published. Saying "couldn't post" here
                    // would be false, and would make people write it again.
                    toasts.error(mediaFailure)
                } else {
                    toasts.success(isEditing ? "Saved" : "Posted")
                }
                onSaved(saved)
                dismiss()
            } catch {
                isSaving = false
                guard !isCancellationError(error) else { return }
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - Media

    /// Hidden while EDITING. `PATCH /api/posts/:id` carries title and body only, and
    /// the media routes are a separate surface — offering a picker here would imply
    /// an edit can swap the photos, which it cannot.
    @ViewBuilder
    private var mediaSection: some View {
        if !isEditing {
            Section {
                if !photoPreviews.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Theme.Spacing.sm) {
                            ForEach(Array(photoPreviews.enumerated()), id: \.offset) { _, image in
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 72, height: 72)
                                    .clipped()
                                    .fwbCorner(Theme.Radius.chip)
                            }
                        }
                    }
                } else if let videoPreview {
                    HStack(spacing: Theme.Spacing.md) {
                        Image(uiImage: videoPreview)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 72, height: 72)
                            .clipped()
                            .fwbCorner(Theme.Radius.chip)
                            .overlay {
                                Image(systemName: "play.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.white)
                                    .shadow(radius: 3)
                            }
                        if let videoDuration {
                            Text("\(Int(videoDuration.rounded()))s")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack(spacing: Theme.Spacing.lg) {
                    // `.borderless` on every control in this row is load-bearing:
                    // a Form row containing plain buttons activates ALL of them on
                    // a row tap — which presented the photo sheet and queued the
                    // video sheet behind it from a single tap.
                    PhotosPicker(
                        selection: $photoItems,
                        maxSelectionCount: PostMediaLimits.maxPhotos,
                        matching: .images
                    ) {
                        Label("Photos", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("composer.photos")

                    PhotosPicker(selection: $videoItem, matching: .videos) {
                        Label("Video", systemImage: "video")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("composer.video")

                    if !photoPreviews.isEmpty || videoPreview != nil {
                        Button("Clear", role: .destructive) {
                            photoItems = []; photoPreviews = []
                            videoItem = nil; videoPreview = nil; videoDuration = nil
                        }
                        .buttonStyle(.borderless)
                        .font(Theme.Typography.caption)
                    }
                }
            } header: {
                Text("Media")
            } footer: {
                Text("Up to \(PostMediaLimits.maxPhotos) photos, or one video under \(Int(PostMediaLimits.maxVideoSeconds)) seconds. Not both.")
            }
        }
    }

    private func loadPhotoPreviews(_ items: [PhotosPickerItem]) async {
        var images: [UIImage] = []
        for item in items.prefix(PostMediaLimits.maxPhotos) {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                images.append(image)
            }
        }
        photoPreviews = images
    }

    /// Validates duration and size at PICK time, not at upload time. A member who
    /// chose a four-minute clip should find out before 90 MB goes over the wire.
    private func loadVideoPreview(_ item: PhotosPickerItem) async {
        guard let movie = try? await item.loadTransferable(type: VideoPayload.self) else {
            error = PostMediaError.unsupportedVideoType.errorDescription
            videoItem = nil
            return
        }
        do {
            let byteSize = (try? Data(contentsOf: movie.url, options: .mappedIfSafe).count) ?? 0
            guard byteSize <= PostMediaLimits.maxVideoBytes else {
                throw PostMediaError.videoTooLarge(byteSize)
            }
            let info = try await PostMediaPreparer.inspectVideo(at: movie.url)
            videoDuration = info.duration
            videoPreview = UIImage(data: info.poster)
            error = nil
        } catch {
            self.error = error.fwbMessage
            videoItem = nil
            videoPreview = nil
            videoDuration = nil
        }
    }

    /// Uploads whatever was picked onto a post that now exists.
    ///
    /// Returns a non-nil message when something failed. The post itself already
    /// landed, so this is reported as a media problem, not a posting one.
    private func attachMedia(to post: ForumPost) async -> String? {
        if !photoItems.isEmpty {
            for (index, item) in photoItems.prefix(PostMediaLimits.maxPhotos).enumerated() {
                mediaProgress = "Uploading photo \(index + 1) of \(photoItems.count)…"
                guard let raw = try? await item.loadTransferable(type: Data.self),
                      let jpeg = PostMediaPreparer.compressPhoto(raw) else { continue }
                do {
                    try await APIClient.shared.uploadPostPhoto(postId: post.id, jpeg: jpeg)
                } catch let APIError.httpError(code, message) where code == 503 {
                    // R2 unprovisioned. The server says so in a sentence meant to be
                    // rendered; the post is fine.
                    return message ?? "Photos aren't available yet."
                } catch {
                    // The server's own sentence. A photo rejected for its
                    // dimensions, one rejected because the member was just banned,
                    // and a dropped connection are three different problems, and
                    // "One of the photos didn't upload." answered none of them.
                    return error.fwbMessage
                }
            }
            return nil
        }

        guard let videoItem,
              let movie = try? await videoItem.loadTransferable(type: VideoPayload.self) else { return nil }
        do {
            mediaProgress = "Preparing video…"
            let data = try Data(contentsOf: movie.url, options: .mappedIfSafe)
            let info = try await PostMediaPreparer.inspectVideo(at: movie.url)

            // The ticket first, so an over-cap upload is refused before the bytes
            // move rather than after.
            let ticket = try await APIClient.shared.videoTicket(
                postId: post.id,
                body: VideoUploadTicketRequest(
                    contentType: "video/quicktime",
                    byteSize: data.count,
                    durationS: info.duration,
                    width: info.size.map { Int($0.width) },
                    height: info.size.map { Int($0.height) }
                )
            )

            mediaProgress = "Uploading video…"
            try await PostMediaPreparer.putToPresignedURL(
                ticket.uploadUrl, data: data, contentType: "video/quicktime")
            try await PostMediaPreparer.putToPresignedURL(
                ticket.posterUploadUrl, data: info.poster, contentType: "image/jpeg")

            mediaProgress = "Finishing up…"
            try await APIClient.shared.attachVideo(
                postId: post.id,
                body: AttachVideoRequest(
                    objectKey: ticket.objectKey,
                    posterObjectKey: ticket.posterObjectKey,
                    contentType: "video/quicktime",
                    byteSize: data.count,
                    durationS: info.duration,
                    width: info.size.map { Int($0.width) },
                    height: info.size.map { Int($0.height) }
                )
            )
            return nil
        } catch let APIError.httpError(code, message) where code == 503 {
            return message ?? "Video isn't available yet."
        } catch {
            return error.fwbMessage
        }
    }
}

/// `PhotosPickerItem` hands a movie over as a file URL, and the file is temporary —
/// it has to be copied somewhere durable before the URL is used, or reading it later
/// races the system's cleanup.
private struct VideoPayload: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { payload in
            SentTransferredFile(payload.url)
        } importing: { received in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("post-video-\(UUID().uuidString).mov")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return VideoPayload(url: destination)
        }
    }
}
