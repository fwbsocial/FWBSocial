import SwiftUI

// MARK: - New channel (admin)
//
// The Channels tab's contextual action for an admin (owner directive 2026-08-11).
// `POST /api/admin/channels`, behind `RequireAdmin` — which re-reads the row on
// every request, so `auth.isAdmin` decides what to DRAW and the server decides
// what is allowed. Same rule as the announcement composer.
//
// # The slug is derived, not typed
//
// `AdminChannelController` deliberately leaves `slug` out of the update route:
// a channel's slug is permanent, and every member route is keyed by it. Asking an
// admin to type a permanent identifier next to the name it is obviously derived
// from is asking for a typo nobody can ever fix. So the slug follows the name,
// and is shown while it does — an admin should see the URL-shaped thing they are
// committing to before they commit to it.
//
// # Why Cancel / Create rather than Done
//
// `DismissableSheet` is right for a sheet you read and close. This one writes, and
// a form whose only exit is "Done" cannot say whether Done meant *save* or
// *abandon*. It follows `PostComposerView` — the app's established write-sheet
// pattern — with the cancellation and confirmation actions in the two corners.

struct ChannelCreateView: View {
    var onCreated: (Channel) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts

    @State private var name = ""
    @State private var summary = ""
    @State private var visibility: ChannelVisibilityOption = .vetted
    @State private var defaultRole: ChannelDefaultRoleOption = .commenter
    @State private var isSaving = false
    @State private var error: String?

    @FocusState private var isNameFocused: Bool

    /// Mirrors the server's `sanitizeProfileString` limit so the member is stopped
    /// by the field rather than by a 400.
    private let maxName = 80

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var slug: String { FWBSlug.kebab(from: trimmedName) }

    private var canSave: Bool {
        !trimmedName.isEmpty && trimmedName.count <= maxName && FWBSlug.isValid(slug) && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .focused($isNameFocused)
                        .submitLabel(.done)
                        .accessibilityIdentifier("channelCreate.name")
                        .accessibilityLabel("Channel name")
                } header: {
                    Text("Name")
                } footer: {
                    nameFooter
                }

                Section {
                    TextField("What's it for?", text: $summary, axis: .vertical)
                        .lineLimit(2...4)
                        .accessibilityIdentifier("channelCreate.description")
                        .accessibilityLabel("Channel description")
                } header: {
                    Text("Description")
                } footer: {
                    Text("Optional. It shows under the name in the channel list.")
                }

                Section {
                    Picker("Who can see it", selection: $visibility) {
                        ForEach(ChannelVisibilityOption.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .accessibilityIdentifier("channelCreate.visibility")
                } header: {
                    Text("Visibility")
                } footer: {
                    Text(visibility.explanation)
                }

                Section {
                    Picker("Members can", selection: $defaultRole) {
                        ForEach(ChannelDefaultRoleOption.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .accessibilityIdentifier("channelCreate.defaultRole")
                } header: {
                    Text("Default role")
                } footer: {
                    Text(defaultRole.explanation)
                }

                if let error {
                    Section { FormErrorText(message: error) }
                }
            }
            // Background layer, never a gesture on the Form itself.
            .fwbDismissKeyboardOnTap()
            .navigationTitle("New channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { save() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("channelCreate.submit")
                }
            }
            .overlay { if isSaving { ProgressView().controlSize(.large) } }
            .fwbAppThemeSurface()
            .task { isNameFocused = true }
        }
    }

    /// The derived slug, or the reason it is not usable yet. Both live in the
    /// footer so the admin reads one line under the field rather than hunting for
    /// a validation message somewhere else on the screen.
    @ViewBuilder
    private var nameFooter: some View {
        if trimmedName.count > maxName {
            Text("\(trimmedName.count) / \(maxName)")
                .foregroundStyle(Theme.Colors.danger)
        } else if trimmedName.isEmpty {
            Text("Members see this name. The channel's permanent address is made from it.")
        } else if FWBSlug.isValid(slug) {
            Text("Address: /\(slug) — permanent, so it won't follow a later rename.")
                .monospaced()
                .accessibilityLabel("Permanent address: \(slug)")
        } else {
            Text("Add a few more letters or numbers — the address needs at least three.")
                .foregroundStyle(Theme.Colors.danger)
        }
    }

    private func save() {
        guard canSave else { return }
        fwbDismissKeyboard()
        isSaving = true
        error = nil

        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = CreateChannelRequest(
            slug: slug,
            name: trimmedName,
            description: trimmedSummary.isEmpty ? nil : trimmedSummary,
            visibility: visibility.rawValue,
            defaultRole: defaultRole.rawValue)

        Task {
            do {
                let created = try await APIClient.shared.createChannel(request)
                isSaving = false
                toasts.success("Created \(created.displayName).")
                onCreated(created)
                dismiss()
            } catch {
                isSaving = false
                guard !isCancellationError(error) else { return }
                // The server writes a real sentence for each of these — a slug
                // collision is 409 "A channel with slug 'x' already exists", which
                // is the single most likely failure here and the one an admin can
                // act on by changing the name.
                self.error = error.fwbMessage
            }
        }
    }
}
