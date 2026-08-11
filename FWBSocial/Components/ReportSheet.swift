import SwiftUI

// MARK: - Report sheet
//
// One sheet for every UGC surface (posts, comments, profiles, announcements),
// matching the server's single `POST /api/reports`. The server's own comment
// says why it is one endpoint rather than one per content type: "a report route
// per content type is how a surface ends up shipping without a report
// affordance, which is exactly the 1.2 rejection this is here to prevent." The
// client mirrors that — one sheet, so a new surface gets reporting by passing a
// target rather than by building a screen.
//
// Guideline 1.2 wants the mechanism reachable from the content itself, which is
// why every caller puts it in the item's own context menu rather than burying it
// in Settings.

struct ReportSheet: View {

    let targetType: ReportTargetType
    let targetId: String
    /// Shown in the header so the reporter can see what they are about to report.
    var subjectName: String?
    /// Offered alongside the report when the target is a person we can block.
    var blockableUserId: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts
    @State private var blocks = BlockStore.shared

    @State private var reason: ReportReason?
    @State private var details = ""
    @State private var isSubmitting = false
    @State private var error: String?
    @State private var alsoBlock = false

    private var canSubmit: Bool { reason != nil && !isSubmitting }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(ReportReason.allCases) { option in
                        Button {
                            reason = option
                        } label: {
                            HStack(spacing: Theme.Spacing.md) {
                                Image(systemName: option.systemImage)
                                    .frame(width: 24)
                                    .foregroundStyle(reason == option ? Theme.Colors.brand : .secondary)
                                    .accessibilityHidden(true)
                                Text(option.label)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if reason == option {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.Colors.brand)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        // Selection was signalled by tint and a checkmark glyph and
                        // nothing else, so VoiceOver read every reason identically and
                        // a member using it could not tell which one they had picked —
                        // on the screen where picking the right one is the whole point.
                        // The glyphs above are hidden because the trait now carries
                        // that meaning, and "checkmark" spoken after the label does not.
                        .accessibilityAddTraits(reason == option ? [.isSelected] : [])
                    }
                } header: {
                    Text("Why are you reporting this \(targetType.subjectNoun)?")
                } footer: {
                    if let subjectName {
                        Text("Reporting \(subjectName).")
                    }
                }

                Section {
                    TextField("Anything else we should know?", text: $details, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Details (optional)")
                } footer: {
                    Text("Moderators review every report, usually within 24 hours.")
                }

                if let blockableUserId, !blocks.isBlocked(blockableUserId) {
                    Section {
                        Toggle("Also block this member", isOn: $alsoBlock)
                    } footer: {
                        Text("You won't see their posts or comments, and they can't reach you.")
                    }
                }

                if let error {
                    Section { FormErrorText(message: error) }
                }
            }
            // Background layer, never `.onTapGesture` on the Form itself — that
            // kills every row control in it (house rule).
            .fwbDismissKeyboardOnTap()
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") { submit() }
                        .disabled(!canSubmit)
                }
            }
            .overlay {
                if isSubmitting {
                    // Unlabelled, this spinner is an unannounced element: VoiceOver
                    // said nothing at all between "Submit" and the sheet dismissing,
                    // so the report appeared to do nothing for several seconds.
                    ProgressView()
                        .controlSize(.large)
                        .accessibilityLabel("Sending your report")
                }
            }
        }
    }

    private func submit() {
        guard let reason else { return }
        fwbDismissKeyboard()
        isSubmitting = true
        error = nil

        Task {
            do {
                try await APIClient.shared.report(
                    targetType: targetType,
                    targetId: targetId,
                    reason: reason,
                    details: details)

                // The block is reported separately from the report itself. It has
                // already been accepted by the server at this point, so a failed
                // block must not fail the sheet — but it must not be described as a
                // success either.
                var blockFailure: String?
                if alsoBlock, let blockableUserId {
                    do {
                        try await APIClient.shared.block(userId: blockableUserId)
                        // `markBlocked` only after the server agreed. It used to run
                        // unconditionally behind a `try?`, so a refused or unreachable
                        // block still flipped the local store and the app told the
                        // member "you won't see their posts, and they can't reach
                        // you" — a Guideline 1.2 safety mechanism claiming to be on
                        // while the server had it off. Silence is the wrong failure
                        // mode for the one control someone reaches for when they feel
                        // unsafe.
                        blocks.markBlocked(blockableUserId)
                    } catch {
                        blockFailure = isCancellationError(error) ? nil : error.fwbMessage
                    }
                }

                isSubmitting = false
                if let blockFailure {
                    toasts.error("Report sent, but we couldn't block them. \(blockFailure)")
                } else {
                    toasts.success("Thanks — a moderator will review this.")
                }
                dismiss()
            } catch {
                isSubmitting = false
                guard !isCancellationError(error) else { return }
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Report/block context menu
//
// The affordance itself, so no surface has to remember to build one. Every UGC
// row gets `.fwbReportMenu(...)` and inherits the whole 1.2 mechanism.

struct ReportMenuButtons: View {
    let targetType: ReportTargetType
    let targetId: String
    var subjectName: String?
    var authorId: String?
    /// Nil when the viewer is the author — you cannot report yourself, and the
    /// server rejects it with a 400 rather than silently accepting.
    var isOwnContent: Bool = false

    @Binding var reportTarget: ReportTargetDescriptor?

    var body: some View {
        if !isOwnContent {
            Button(role: .destructive) {
                reportTarget = ReportTargetDescriptor(
                    targetType: targetType,
                    targetId: targetId,
                    subjectName: subjectName,
                    blockableUserId: authorId)
            } label: {
                Label("Report", systemImage: "flag")
            }
        }
    }
}

/// What a surface hands to its `.sheet(item:)` to open the report sheet. Carried
/// as one value so a view needs a single piece of state rather than four.
struct ReportTargetDescriptor: Identifiable, Equatable {
    let targetType: ReportTargetType
    let targetId: String
    var subjectName: String?
    var blockableUserId: String?

    var id: String { "\(targetType.rawValue):\(targetId)" }
}

extension View {
    /// Presents the report sheet for whichever target is set.
    func fwbReportSheet(_ target: Binding<ReportTargetDescriptor?>) -> some View {
        sheet(item: target) { descriptor in
            ReportSheet(
                targetType: descriptor.targetType,
                targetId: descriptor.targetId,
                subjectName: descriptor.subjectName,
                blockableUserId: descriptor.blockableUserId)
        }
    }
}
