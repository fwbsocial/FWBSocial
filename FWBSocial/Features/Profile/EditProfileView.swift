import PhotosUI
import SwiftUI

// MARK: - Edit profile
//
// The owner-editable half of the Profile tab: photo, display name, `@username`,
// bio. Reached from ProfileView's "Edit profile" row.
//
// # Username, and why the checking is live
//
// A handle is claimed on a first-come basis against a partial unique index, so
// the only two honest answers are "nobody holds this right now" and "someone
// does". Typing a name, tapping Save, and being told thirty seconds later that
// it was gone is the worst version of that; a debounced check
// (`GET /api/auth/username-availability`) turns it into something the member
// resolves while they are still thinking about it.
//
// **Every decision here switches on `status` and `code`, never on the English in
// `reason`.** `reason` is displayed verbatim — it is the server's sentence, it
// moves with the rules, and re-deriving it here would mean two sets of rules
// that drift. What the client owns is the icon, the colour and whether Save is
// live.
//
// The check is a courtesy and never the enforcement: `PUT /api/auth/profile`
// can still answer 409 (someone claimed it in between) or 422, and both land
// back on this field rather than in an anonymous banner.
//
// # Photo
//
// `POST /api/auth/avatar` takes ≤1 MB of JPEG/PNG/HEIC, so the picked image is
// centre-cropped square and downscaled here before it goes anywhere
// (`AvatarPreparer`). The route answers the whole user, which is what makes the
// new photo appear everywhere at once — see `AuthService.uploadAvatar`.
//
// There is no remove-avatar route on the server, so this offers "change", not
// "remove".

struct EditProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts

    @State private var auth = AuthService.shared

    // Seeded at construction rather than in `onAppear`: the sheet's body is
    // built when it is presented, and seeding here removes any ordering question
    // between `onAppear` and the `task(id:)` that watches the username.
    @State private var displayName: String = AuthService.shared.user?.displayName ?? ""
    @State private var username: String = AuthService.shared.user?.username ?? ""
    @State private var bio: String = AuthService.shared.user?.bio ?? ""

    @State private var usernameState: UsernameFieldState = .idle
    @State private var isSaving = false
    @State private var errorMessage: String?

    @State private var pickedPhoto: PhotosPickerItem?
    @State private var isUploadingPhoto = false

    /// The handle the server currently holds for this member. Retyping it is not
    /// a change, and must not read as a collision with themselves.
    private var storedUsername: String { auth.user?.username ?? "" }

    private var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var usernameChanged: Bool {
        trimmedUsername.lowercased() != storedUsername.lowercased()
    }

    /// Mirrors the server's `displayName` guard (1–50) so the member is stopped
    /// by the field rather than by a 400.
    private var canSave: Bool {
        !displayName.trimmed.isEmpty
            && displayName.trimmed.count <= 50
            && !usernameState.blocksSave
            && !isSaving
            && !isUploadingPhoto
    }

    var body: some View {
        NavigationStack {
            Form {
                photoSection
                nameSection
                usernameSection
                bioSection

                if let errorMessage {
                    Section { FormErrorText(message: errorMessage) }
                }
            }
            // Background layer, never a gesture on the Form itself.
            .fwbDismissKeyboardOnTap()
            .navigationTitle("Edit profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("editProfile.save")
                }
            }
            .fwbAppThemeSurface()
            // `task(id:)` IS the debounce: SwiftUI cancels the previous run on
            // every keystroke, so the sleep below only ever completes for the
            // last one. A hand-rolled Task + timer would have to reimplement
            // exactly that, less reliably.
            .task(id: username) { await checkUsername() }
            .onChange(of: pickedPhoto) { _, item in
                guard let item else { return }
                uploadPhoto(item)
            }
        }
    }

    // MARK: Photo

    private var photoSection: some View {
        Section {
            HStack {
                Spacer()
                PhotosPicker(selection: $pickedPhoto, matching: .images, photoLibrary: .shared()) {
                    ZStack(alignment: .bottomTrailing) {
                        AvatarView(name: auth.user?.displayName ?? displayName,
                                   url: auth.user?.avatarUrl,
                                   size: 96)
                            .opacity(isUploadingPhoto ? 0.4 : 1)
                        // Glyph-only, so it is a circle — never a capsule
                        // (house chrome rule).
                        Image(systemName: "camera.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.Colors.onBrand)
                            .frame(width: 32, height: 32)
                            .background(Theme.Colors.brand, in: Circle())
                            .overlay(Circle().strokeBorder(Theme.Colors.surface, lineWidth: 2))
                    }
                    .overlay { if isUploadingPhoto { ProgressView() } }
                }
                .buttonStyle(.borderless)
                .disabled(isUploadingPhoto)
                .accessibilityIdentifier("editProfile.photo")
                .accessibilityLabel(auth.user?.avatarUrl == nil ? "Add a profile photo" : "Change your profile photo")
                .accessibilityHint("Opens your photo library")
                Spacer()
            }
            .padding(.vertical, Theme.Spacing.xs)
        } footer: {
            Text(isUploadingPhoto
                 ? "Uploading your photo…"
                 : "Tap your photo to change it. It's cropped square and resized on this device before it's uploaded.")
                .fwbOnCanvas()
        }
    }

    // MARK: Display name

    private var nameSection: some View {
        Section {
            TextField("Your name", text: $displayName)
                .textInputAutocapitalization(.words)
                .accessibilityIdentifier("editProfile.displayName")
                .accessibilityLabel("Display name")
        } header: {
            Text("Display name").fwbOnCanvas()
        } footer: {
            Text("Up to 50 characters. This is the name other members see.").fwbOnCanvas()
        }
    }

    // MARK: Username

    private var usernameSection: some View {
        Section {
            HStack(spacing: 2) {
                Text("@")
                    .foregroundStyle(.secondary)
                    // The prefix is decoration; VoiceOver reads the field's own
                    // label, and an "at sign" announcement before it is noise.
                    .accessibilityHidden(true)
                TextField("username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                    .submitLabel(.done)
                    .accessibilityIdentifier("editProfile.username")
                    .accessibilityLabel("Username")
            }
            usernameStatusRow
        } header: {
            Text("Username").fwbOnCanvas()
        } footer: {
            Text("3–30 characters: letters, numbers, underscores and periods. Saved in lowercase.")
                .fwbOnCanvas()
        }
    }

    @ViewBuilder
    private var usernameStatusRow: some View {
        switch usernameState {
        case .idle:
            EmptyView()
        case .checking:
            statusRow(text: "Checking…", tint: .secondary) {
                ProgressView().controlSize(.small)
            }
        case .current:
            statusRow(text: "This is your username", tint: .secondary) {
                Image(systemName: "person.crop.circle")
            }
        case .available(let canonical):
            statusRow(text: "@\(canonical) is available", tint: Theme.Colors.positive) {
                Image(systemName: "checkmark.circle.fill")
            }
        case .taken(let message):
            statusRow(text: message, tint: Theme.Colors.danger) {
                Image(systemName: "xmark.circle.fill")
            }
        case .invalid(let message):
            statusRow(text: message, tint: Theme.Colors.caution) {
                Image(systemName: "exclamationmark.circle.fill")
            }
        case .unreachable:
            statusRow(text: "We couldn't check that just now. You can still save.", tint: .secondary) {
                Image(systemName: "wifi.exclamationmark")
            }
        }
    }

    private func statusRow(
        text: String,
        tint: Color,
        @ViewBuilder icon: () -> some View
    ) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            icon()
            Text(text)
            Spacer(minLength: 0)
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(tint)
        // One label for the pair, so VoiceOver says the sentence rather than
        // "checkmark circle fill, @ada is available".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityIdentifier("editProfile.usernameStatus")
    }

    // MARK: Bio

    private var bioSection: some View {
        Section {
            TextField("A line about you", text: $bio, axis: .vertical)
                .lineLimit(3...6)
                .accessibilityIdentifier("editProfile.bio")
                .accessibilityLabel("Bio")
        } header: {
            Text("Bio").fwbOnCanvas()
        }
    }

    // MARK: - Availability

    /// Debounced live check. Runs inside `task(id: username)`, so it is cancelled
    /// and restarted on every keystroke and only the settled value reaches the
    /// network.
    private func checkUsername() async {
        let candidate = trimmedUsername

        // Nothing to ask about: empty (the member is clearing the field, and an
        // omitted username is left alone by the server) or unchanged.
        guard !candidate.isEmpty else {
            usernameState = .idle
            return
        }
        guard usernameChanged else {
            usernameState = .idle
            return
        }

        usernameState = .checking
        do {
            try await Task.sleep(for: .milliseconds(400))
        } catch {
            return  // superseded by the next keystroke
        }

        do {
            let result = try await auth.usernameAvailability(candidate)
            // The field may have moved on while the request was in flight — a
            // cancelled task's result must never overwrite a newer state.
            guard !Task.isCancelled else { return }
            usernameState = .init(result)
        } catch {
            guard !isCancellationError(error), !Task.isCancelled else { return }
            // Rate limited, offline, 500 — all the same to the member: we don't
            // know. Save stays live, because the write is the real gate.
            usernameState = .unreachable
        }
    }

    // MARK: - Photo upload

    private func uploadPhoto(_ item: PhotosPickerItem) {
        isUploadingPhoto = true
        errorMessage = nil
        Task {
            defer {
                isUploadingPhoto = false
                // Clear the selection so picking the SAME photo again still
                // fires `onChange` — otherwise a failed upload can't be retried
                // without choosing something else first.
                pickedPhoto = nil
            }
            do {
                guard let raw = try await item.loadTransferable(type: Data.self),
                      let jpeg = AvatarPreparer.squareJPEG(from: raw)
                else { throw AvatarError.unreadableImage }

                try await auth.uploadAvatar(jpeg)
                toasts.success("Photo updated")
            } catch {
                guard !isCancellationError(error) else { return }
                errorMessage = error.fwbMessage
            }
        }
    }

    // MARK: - Save

    private func save() {
        guard canSave else { return }
        fwbDismissKeyboard()
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await auth.updateProfile(
                    AuthService.ProfileUpdate(
                        displayName: displayName.trimmed,
                        // Omitted when unchanged: the server leaves an absent
                        // field alone, and sending the current handle back would
                        // make every save race the unique index for no reason.
                        username: usernameChanged && !trimmedUsername.isEmpty ? trimmedUsername : nil,
                        bio: bio.trimmed.isEmpty ? nil : bio.trimmed))
                toasts.success("Profile updated")
                dismiss()
            } catch AuthError.usernameTaken(let message) {
                // Claimed between the check and the write. The field owns this,
                // not a banner at the bottom of the form.
                usernameState = .taken(message)
            } catch AuthError.usernameRejected(let message) {
                usernameState = .invalid(message)
            } catch {
                errorMessage = error.fwbMessage
            }
            isSaving = false
        }
    }
}

// MARK: - Username field state

/// What the field is showing, derived from the server's `status` / `code`.
///
/// `unreachable` is deliberately NOT a blocking state: failing to *ask* whether
/// a name is free is not evidence that it isn't, and refusing to save because a
/// courtesy request timed out would strand a member behind an optional feature.
enum UsernameFieldState: Equatable {
    /// Empty, or unchanged from what the server already holds.
    case idle
    case checking
    /// Free. Carries the canonical form — the lowercased handle that would
    /// actually be stored, which is what the member is shown.
    case available(String)
    /// The member's own handle.
    case current
    case taken(String)
    case invalid(String)
    case unreachable

    init(_ dto: UsernameAvailabilityDTO) {
        switch dto.parsedStatus {
        case .available: self = .available(dto.username)
        case .current:   self = .current
        case .taken:     self = .taken(dto.refusalMessage ?? UsernameRuleCode.taken.fallbackMessage)
        case .invalid:   self = .invalid(dto.refusalMessage ?? "That username isn't valid")
        case nil:
            // A status this build doesn't know. Fall back to the boolean, which
            // is part of the same contract, rather than guessing.
            self = dto.available ? .available(dto.username)
                                 : .invalid(dto.refusalMessage ?? "That username isn't available")
        }
    }

    var blocksSave: Bool {
        switch self {
        case .checking, .taken, .invalid: true
        case .idle, .available, .current, .unreachable: false
        }
    }
}

#Preview {
    EditProfileView()
        .environment(ToastCenter())
}
