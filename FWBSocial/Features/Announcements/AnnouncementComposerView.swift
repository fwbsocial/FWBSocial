import SwiftUI

// MARK: - Admin composer
//
// Create and edit announcements (PLAN.md §4.1 / §5.4). Drawn only when
// `AuthUser.isAdmin`; enforced by the server's `RequireAdmin` on
// `/api/admin/announcements`.
//
// Publishing is a separate, explicit action rather than a side effect of saving:
// publishing is what fans out the push to the membership, and the server guards
// a double-push with `push_sent_at`. An admin should never discover they
// notified everyone because they fixed a typo.

struct AnnouncementComposerView: View {
    /// `nil` creates; otherwise edits in place.
    let existing: Announcement?
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts

    @State private var title = ""
    @State private var body_ = ""
    @State private var visibility = "public"
    @State private var isPinned = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showPublishConfirm = false

    private var isEditing: Bool { existing != nil }

    private var canSave: Bool {
        !title.trimmed.isEmpty && !body_.trimmed.isEmpty && !isWorking
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Announcement") {
                    TextField("Title", text: $title)
                        .textInputAutocapitalization(.sentences)
                    TextField("Body", text: $body_, axis: .vertical)
                        .lineLimit(6...20)
                        .textInputAutocapitalization(.sentences)
                }

                Section {
                    Picker("Visibility", selection: $visibility) {
                        Text("Everyone").tag("public")
                        Text("Vetted members").tag("vetted")
                    }
                    Toggle("Pin to top", isOn: $isPinned)
                } footer: {
                    Text(visibility == "public"
                         ? "Readable by anyone, including signed-out visitors."
                         : "Only visible to members who've been vetted.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(Theme.Colors.danger)
                    }
                }

                if isEditing, existing?.isDraft == true {
                    Section {
                        Button("Publish now") { showPublishConfirm = true }
                            .disabled(isWorking)
                    } footer: {
                        Text("Publishing notifies members who have announcement notifications turned on. It only sends once — re-publishing later won't notify anyone twice.")
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit announcement" : "New announcement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Create") { save(publish: false) }
                        .disabled(!canSave)
                }
            }
            .confirmationDialog("Publish this announcement?", isPresented: $showPublishConfirm, titleVisibility: .visible) {
                Button("Publish") { save(publish: true) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Members with announcement notifications on will get a push.")
            }
            .onAppear(perform: prefill)
            .disabled(isWorking)
            .overlay {
                if isWorking {
                    ProgressView().controlSize(.large)
                }
            }
        }
    }

    private func prefill() {
        guard let existing else { return }
        title = existing.title ?? ""
        body_ = existing.body ?? ""
        visibility = existing.visibility ?? "public"
        isPinned = existing.pinned
    }

    private func save(publish: Bool) {
        guard canSave else { return }
        isWorking = true
        errorMessage = nil
        Task {
            do {
                let saved: Announcement
                if let existing {
                    saved = try await APIClient.shared.updateAnnouncement(
                        id: existing.id,
                        UpdateAnnouncementRequest(
                            title: title.trimmed,
                            body: body_.trimmed,
                            visibility: visibility,
                            isPinned: isPinned))
                } else {
                    // Created as a draft — the server only pushes on publish, so
                    // creating and publishing stay two deliberate steps.
                    saved = try await APIClient.shared.createAnnouncement(
                        CreateAnnouncementRequest(
                            title: title.trimmed,
                            body: body_.trimmed,
                            visibility: visibility,
                            isPinned: isPinned))
                }

                if publish {
                    let result = try await APIClient.shared.publishAnnouncement(id: saved.id)
                    if result.pushSkippedAlreadySent == true {
                        toasts.success("Published — members were already notified")
                    } else if let delivered = result.pushDelivered {
                        toasts.success("Published — notified \(delivered) device\(delivered == 1 ? "" : "s")")
                    } else {
                        toasts.success("Published")
                    }
                } else {
                    toasts.success("Saved")
                }
                onSaved()
                dismiss()
            } catch {
                errorMessage = error.fwbMessage
            }
            isWorking = false
        }
    }
}
