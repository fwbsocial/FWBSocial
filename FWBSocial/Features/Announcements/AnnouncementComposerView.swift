import SwiftUI

// MARK: - Admin composer
//
// Create and edit announcements (PLAN.md §4.1 / §5.4). Drawn only when
// `AuthUser.isAdmin`; enforced by the server's `RequireAdmin` on
// `/api/admin/announcements`.
//
// Publishing stays an EXPLICIT act, not a side effect of saving: it is what fans
// out the push to the membership, and the server guards a double-push with
// `push_sent_at`. An admin should never discover they notified everyone because
// they fixed a typo.
//
// The "Publish now" toggle is that explicit act, defaulted OFF so the save button
// still means "save a draft" exactly as it always did. On the wire it is still
// create-then-publish against the two existing endpoints — the server's create
// route only ever makes drafts, and publish is the one place the fan-out lives,
// so routing through it is what keeps "pushes exactly once" a property of one
// code path rather than two.

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
    @State private var publishNow = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showPublishConfirm = false

    private var isEditing: Bool { existing != nil }

    private var canSave: Bool {
        !title.trimmed.isEmpty && !body_.trimmed.isEmpty && !isWorking
    }

    /// A new announcement, or an existing one still in draft.
    private var canPublish: Bool { existing == nil || existing?.isDraft == true }

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

                // Offered while the announcement is still a draft — which is
                // every new one, and an existing one that has not gone out yet.
                // Once it is published there is nothing left for this to do.
                if canPublish {
                    Section {
                        Toggle("Publish now", isOn: $publishNow)
                            .accessibilityIdentifier("composer.publishNow")
                            .accessibilityHint("Publishes on save and notifies members who have announcement notifications on")
                    } footer: {
                        Text(publishNow
                             ? "Goes out as soon as you \(isEditing ? "save" : "create") it. Members with announcement notifications on will get a push — once, even if you edit and save again later."
                             : "Off: saved as a draft. Only admins can see it, and nobody is notified until you publish.")
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
                    Button(isEditing ? "Save" : "Create") {
                        // The toggle is deliberate, but the confirmation stays:
                        // this is the one button in the app that notifies the
                        // entire membership, and it cannot be taken back.
                        if publishNow { showPublishConfirm = true } else { save(publish: false) }
                    }
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
