import SwiftUI

// MARK: - Post composer
//
// **Text-first, and text-only.** Plan §8 defers multi-image posts, and the brief
// for this phase cuts the picker entirely — so there is deliberately no
// `PhotosPicker` here. The server's `CreatePostRequest` is `{ title, body }` and
// nothing else; `fwb_post_media` exists in the schema but no route writes it yet.
// Adding a picker now would mean an attachment button that cannot attach.
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
                if isSaving { ProgressView().controlSize(.large) }
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
                isSaving = false
                toasts.success(isEditing ? "Saved" : "Posted")
                onSaved(saved)
                dismiss()
            } catch {
                isSaving = false
                guard !isCancellationError(error) else { return }
                self.error = error.localizedDescription
            }
        }
    }
}
