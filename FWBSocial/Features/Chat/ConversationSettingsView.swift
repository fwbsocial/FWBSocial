import SwiftUI

// MARK: - Conversation settings
//
// Ported from Cove's `GroupConversationSettingsView` (ContactsSettingsViews.swift
// 1663–2355, ~700 LoC). The brief keeps the safety-number sheet and the device
// affordances — those are in scope, they ARE the trust story — and strips only the
// Commune-specific badges: the Off-Grid state chip, the nudge row, the Deep End
// entry and the Stash transfer lab.
//
// The message-TTL control lives here because PLAN.md §2.8 puts it here: a
// per-conversation override of 30 / 90 / 365 / off, over a server default of 365
// (commissioner decision 10). "Off" is offered and is never the default — it makes
// storage unbounded on a single small machine, and an indefinite ciphertext archive
// is the weaker security posture, not the stronger one.

struct ConversationSettingsView: View {
    let conversationId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var chat = ChatService.shared
    @State private var titleDraft = ""
    @State private var ttl: MessageTTL = .oneYear
    @State private var isConfirmingLeave = false
    @State private var errorMessage: String?

    private var conversation: ChatConversation? { chat.conversation(conversationId) }

    /// The retention the server currently believes in, as opposed to `ttl`, which is
    /// what the picker is showing. Keeping the two distinct is what lets a failed
    /// write put the picker back where it was.
    private var serverTTL: MessageTTL { MessageTTL.from(seconds: conversation?.disappearingSeconds) }

    var body: some View {
        Form {
            if let conversation {
                if conversation.isGroup {
                    Section("Name") {
                        TextField("Group name", text: $titleDraft)
                            .onSubmit { Task { await saveTitle() } }
                    }
                }

                Section {
                    LabeledContent("Protection") {
                        Text(conversation.requireQuantum ? "Quantum-secure" : "Standard")
                    }
                    NavigationLink {
                        SafetyNumberView(conversationId: conversationId)
                    } label: {
                        Label("Safety number", systemImage: "number.square")
                    }
                    .accessibilityIdentifier("chat.safetyNumber")
                } header: {
                    Text("Encryption")
                } footer: {
                    Text("Compare the safety number with the other person — out loud, or side by side — to be certain no one is in the middle. It changes when someone adds or replaces a device.")
                }

                Section {
                    Picker("Delete messages after", selection: $ttl) {
                        ForEach(MessageTTL.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .onChange(of: ttl) { _, newValue in
                        // Only write when the picker has actually moved away from the
                        // server's value. That skips two writes nobody asked for: the
                        // one `.task` used to trigger just by seeding the picker, and
                        // the one a revert below would otherwise trigger on its way
                        // back.
                        guard newValue != serverTTL else { return }
                        Task { await saveTTL(newValue) }
                    }
                } header: {
                    Text("Message history")
                } footer: {
                    Text("Applies to everyone in this conversation, on the server and on each device. Turning it off keeps messages until someone deletes them.")
                }

                Section("Notifications") {
                    Toggle("Mute this conversation", isOn: Binding(
                        get: { conversation.muted },
                        set: { newValue in Task { await chat.setMuted(newValue, conversationId: conversationId) } }
                    ))
                }

                Section("People") {
                    ForEach(conversation.memberIds, id: \.self) { memberId in
                        HStack(spacing: Theme.Spacing.md) {
                            AvatarView(name: chat.name(for: memberId), url: nil)
                                .frame(width: 32, height: 32)
                            Text(chat.name(for: memberId))
                            Spacer()
                            if memberId == conversation.createdBy {
                                StatusBadge("Created it")
                            }
                        }
                    }
                }

                Section {
                    Button(conversation.isGroup ? "Leave conversation" : "Delete conversation", role: .destructive) {
                        isConfirmingLeave = true
                    }
                    .accessibilityIdentifier("chat.leave")
                } footer: {
                    Text("You'll stop receiving messages. Messages already on other people's devices stay there — we can't reach them.")
                }

                if let errorMessage {
                    Section { FormErrorText(message: errorMessage) }
                }
            } else if chat.isLoadingConversations {
                Section {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            } else if let conversationsError = chat.conversationsError {
                // Same order as everywhere else — loading, then error, then the
                // "we looked and it isn't there" state below. Without this branch the
                // whole Form rendered as a blank screen under a "Details" title, which
                // reads as a broken app rather than as a failed fetch.
                Section {
                    ErrorStateView(error: conversationsError) {
                        Task { await chat.refreshConversations() }
                    }
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    EmptyStateView(
                        icon: "bubble.left.and.exclamationmark.bubble.right",
                        title: "Conversation unavailable",
                        message: "We can't find this conversation any more. It may have been deleted, or you may have left it on another device.")
                    .listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // A cold launch straight into this screen (a notification tap, a restored
            // scene) can arrive before the conversation list exists, and the settings
            // for a conversation we haven't loaded are not settings at all.
            if conversation == nil { await chat.refreshConversations() }
            titleDraft = conversation?.title ?? ""
            ttl = serverTTL
        }
        .confirmationDialog("Leave this conversation?", isPresented: $isConfirmingLeave, titleVisibility: .visible) {
            Button("Leave", role: .destructive) {
                Task {
                    do {
                        try await chat.leave(conversationId)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    // MARK: - Writes
    //
    // Both of these used to be `try? await` — the call fired, the error was dropped
    // on the floor, and the control kept showing the value the member had just
    // chosen. The screen therefore disagreed with the server and said nothing about
    // it, which for the TTL below is not a cosmetic problem: it is a retention
    // control silently failing to apply.

    private func saveTitle() async {
        let previous = conversation?.title ?? ""
        do {
            try await chat.setTitle(titleDraft, conversationId: conversationId)
            errorMessage = nil
        } catch {
            guard !isCancellationError(error) else { return }
            // Put the field back to the name the group actually has, so nobody walks
            // away believing they renamed it.
            titleDraft = previous
            errorMessage = error.fwbMessage
        }
    }

    private func saveTTL(_ newValue: MessageTTL) async {
        let previous = serverTTL
        do {
            try await chat.setMessageTTL(newValue, conversationId: conversationId)
            errorMessage = nil
        } catch {
            guard !isCancellationError(error) else { return }
            // Reverting matters more here than anywhere else on this screen. Leaving
            // the picker on "30 days" after the write failed tells everyone in the
            // conversation their messages are being deleted on a schedule that is not
            // running — a security control that is off while claiming to be on.
            ttl = previous
            errorMessage = error.fwbMessage
        }
    }
}

// MARK: - Safety number
//
// Ported from Cove's `SafetyNumberView` (~830 LoC). Revision 3 of the plan omitted
// it from the keep-set entirely; the brief restores it, and correctly — the safety
// number is the ONLY defence against a server that substitutes a device key, and
// PLAN.md §4.3.3's TOFU pin is only half the story without an out-of-band compare.

struct SafetyNumberView: View {
    let conversationId: UUID

    @State private var chat = ChatService.shared
    @State private var number: String?
    @State private var deviceCount = 0
    @State private var isVerified = false
    @State private var isLoading = true

    var body: some View {
        Form {
            Section {
                if isLoading {
                    ProgressView()
                } else if let number {
                    Text(number)
                        .font(.system(.title3, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Spacing.md)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("chat.safetyNumber.digits")
                } else {
                    Text("Not available yet — no verified devices in this conversation.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Safety number")
            } footer: {
                Text("Covers \(deviceCount) device\(deviceCount == 1 ? "" : "s"). Both of you should see the same 30 digits.")
            }

            if let number {
                Section {
                    Toggle("I've verified this", isOn: Binding(
                        get: { isVerified },
                        set: { newValue in
                            isVerified = newValue
                            Task {
                                await chat.setSafetyNumberVerified(
                                    newValue, conversationId: conversationId, safetyNumber: number
                                )
                            }
                        }
                    ))
                    .accessibilityIdentifier("chat.safetyNumber.verified")
                } footer: {
                    // The mark is stored against the EXACT number, so it un-verifies
                    // itself when the device set changes. A "verified" badge that
                    // survived a new device would be a lie.
                    Text("If anyone adds or replaces a device, this number changes and you'll be asked to check it again.")
                }
            }

            if let changed = chat.pendingKeyChanges[conversationId], !changed.isEmpty {
                Section {
                    ForEach(changed) { device in
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            Text(device.deviceName).font(Theme.Typography.rowTitle)
                            Text("This device's keys changed since you last saw it. Messages aren't being sent to it.")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(.secondary)
                            Button("I've checked — trust it again") {
                                Task {
                                    await chat.acceptKeyChange(device, conversationId: conversationId)
                                    await load()
                                }
                            }
                            .font(Theme.Typography.caption.weight(.semibold))
                        }
                        .padding(.vertical, Theme.Spacing.xs)
                    }
                } header: {
                    Text("Changed devices")
                }
            }
        }
        .navigationTitle("Safety number")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        let result = await chat.safetyNumber(for: conversationId)
        number = result.number
        deviceCount = result.deviceCount
        isVerified = result.isVerified
        isLoading = false
    }
}
