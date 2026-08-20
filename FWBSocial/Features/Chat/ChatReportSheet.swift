import SwiftUI

// MARK: - Chat report with evidence-bundle preview
//
// PLAN.md §4.7, and §5.4 makes the preview a requirement rather than a nicety:
// "the member sees exactly which messages and whose words are leaving their device,
// and can trim the context range before sending".
//
// # Why the client has to do this at all
//
// The server holds ciphertext. Only a participant's device can produce plaintext, so
// a chat report that carried just a message id would be uninvestigable — the server
// literally cannot fetch what was said. `ReportController` refuses one: *"A chat
// report must include the evidence bundle — the server cannot read encrypted
// messages."*
//
// # The honesty this screen owes the member
//
// They are disclosing a third party's words. So the bundle is shown in full, in the
// order it will be sent, with the reported message marked — and the context range is
// theirs to set. The copy says plainly where it goes and how long it is kept
// (commissioner decision 13: one year, encrypted at rest under a key that is not
// used for anything else).
//
// The evidence is **attested, not proven** — a malicious reporter could fabricate
// text. Triage corroborates it against server-held metadata (those message ids
// really exist, in that conversation, from that sender, at those times), which
// catches the fabrications that matter without pretending to a guarantee E2EE cannot
// give.

struct ChatReportSheet: View {
    let message: ChatMessage
    let conversationId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var chat = ChatService.shared
    @State private var reason: ReportReason = .harassment
    @State private var details = ""
    @State private var contextCount = 3
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var didSubmit = false

    /// The reported message plus up to `contextCount` messages either side, in
    /// order. Context is capped because "surrounding context" that runs to a hundred
    /// messages is a transcript, not a report.
    private var bundleMessages: [ChatMessage] {
        let all = chat.messagesByConversation[conversationId] ?? []
        guard let index = all.firstIndex(where: { $0.id == message.id }) else { return [message] }
        let lower = max(0, index - contextCount)
        let upper = min(all.count - 1, index + contextCount)
        return Array(all[lower ... upper]).filter { $0.decryptedText != nil }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Reason", selection: $reason) {
                        ForEach(ReportReason.allCases) { option in
                            Label(option.label, systemImage: option.systemImage).tag(option)
                        }
                    }
                    TextField("Anything else we should know? (optional)", text: $details, axis: .vertical)
                        .lineLimit(2 ... 5)
                } header: {
                    Text("Why are you reporting this?")
                }

                Section {
                    Stepper("Include \(contextCount) message\(contextCount == 1 ? "" : "s") either side", value: $contextCount, in: 0 ... 10)
                } header: {
                    Text("Context")
                } footer: {
                    Text("Context helps a moderator understand what happened. Everything you include is sent.")
                }

                Section {
                    ForEach(bundleMessages) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: Theme.Spacing.xs) {
                                Text(chat.isMine(entry) ? "You" : chat.name(for: entry.senderId))
                                    .font(Theme.Typography.caption.weight(.semibold))
                                Text(entry.createdAt, format: .dateTime.hour().minute())
                                    .font(Theme.Typography.micro)
                                    .foregroundStyle(.tertiary)
                                if entry.id == message.id {
                                    StatusBadge("Reported", color: Theme.Colors.danger)
                                }
                            }
                            Text(entry.decryptedText ?? "")
                                .font(Theme.Typography.preview)
                        }
                        .padding(.vertical, 2)
                        // One stop per message, not four. Left alone, VoiceOver walked
                        // the sender, the timestamp, the "Reported" badge and the body
                        // as separate elements, so auditing the bundle — the entire
                        // reason this preview exists — took four swipes per message and
                        // scattered the badge away from the message it marks.
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(evidenceLabel(for: entry))
                    }
                } header: {
                    Text("Exactly what will be sent")
                } footer: {
                    Text("This is the only way a moderator can see a private message — we can't read them ourselves. It's stored encrypted, kept for one year, and only seen by whoever handles this report.")
                }

                if let errorMessage {
                    Section { FormErrorText(message: errorMessage) }
                }
            }
            // Background layer, never `.onTapGesture` on the Form itself — that
            // kills every row control in it (house rule).
            .fwbDismissKeyboardOnTap()
            .navigationTitle("Report message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { Task { await submit() } }
                        .disabled(isSubmitting || bundleMessages.isEmpty)
                        // What this button does is not what "Send" implies anywhere
                        // else in an end-to-end encrypted app: it decrypts private
                        // messages on this device and hands the plaintext to a human
                        // moderator. A member who cannot see the bundle listed above
                        // has no other way to learn that before they commit.
                        .accessibilityHint("Decrypts the \(bundleMessages.count) message\(bundleMessages.count == 1 ? "" : "s") listed above and sends their text to moderators. Kept for one year.")
                        .accessibilityIdentifier("chat.report.send")
                }
            }
            .alert("Report sent", isPresented: $didSubmit) {
                Button("Done") { dismiss() }
            } message: {
                Text("A moderator will look at this within 24 hours. You can also block this person from their profile.")
            }
        }
    }

    /// One spoken sentence per bundled message, in the order the row draws it, with
    /// the reported one called out by name rather than by a badge colour.
    private func evidenceLabel(for entry: ChatMessage) -> String {
        let who = chat.isMine(entry) ? "You" : chat.name(for: entry.senderId)
        let when = entry.createdAt.formatted(date: .omitted, time: .shortened)
        let marker = entry.id == message.id ? " Reported message." : ""
        return "\(who), \(when).\(marker) \(entry.decryptedText ?? "")"
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await APIClient.shared.reportChatMessage(
                messageId: message.id,
                reason: reason,
                details: details,
                bundle: ChatEvidenceBundleBody(
                    conversationId: conversationId,
                    messages: bundleMessages.compactMap { entry in
                        guard let text = entry.decryptedText else { return nil }
                        return ChatEvidenceBundleBody.Message(
                            messageId: entry.id,
                            senderId: entry.senderId,
                            sentAt: entry.createdAt,
                            text: text,
                            isReported: entry.id == message.id
                        )
                    }
                )
            )
            didSubmit = true
        } catch {
            errorMessage = error.fwbMessage
        }
    }
}

// MARK: - Wire

/// Mirrors fwb-server's `ChatEvidenceBundle`.
nonisolated struct ChatEvidenceBundleBody: Encodable, Sendable {
    nonisolated struct Message: Encodable, Sendable {
        let messageId: UUID
        let senderId: UUID
        /// The server timestamp as this client observed it — checked against
        /// server-held metadata at triage, which is what makes a fabricated message
        /// id detectable.
        let sentAt: Date
        let text: String
        let isReported: Bool
    }

    let conversationId: UUID
    let messages: [Message]
}

private nonisolated struct CreateChatReportRequest: Encodable, Sendable {
    let targetType: String
    let targetId: UUID
    let reason: String
    let details: String?
    let evidence: ChatEvidenceBundleBody
}

extension APIClient {
    /// The chat variant of `POST /api/reports`. Kept separate from the generic
    /// `report(...)` because the evidence bundle is mandatory here and impossible
    /// everywhere else — a shared optional field would imply every surface can attest
    /// chat plaintext.
    @discardableResult
    func reportChatMessage(
        messageId: UUID,
        reason: ReportReason,
        details: String,
        bundle: ChatEvidenceBundleBody
    ) async throws -> ReportResponse {
        let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await post("/api/reports", body: CreateChatReportRequest(
            targetType: ReportTargetType.chatMessage.rawValue,
            targetId: messageId,
            reason: reason.rawValue,
            details: trimmed.isEmpty ? nil : trimmed,
            evidence: bundle
        ))
    }
}
