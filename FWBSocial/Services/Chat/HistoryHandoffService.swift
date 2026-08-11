import CryptoKit
import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: "events.fwb.social", category: "Handoff")

// MARK: - Device-approval history handoff (PLAN-ADDENDUM A2)
//
// **A committed deliverable, not an optional.** The owner's expectation — and the
// correct product behaviour — is that approving a new device from a still-live old
// device preserves the member's full message history.
//
// Cove as shipped does not do that. It re-wraps GROUP keys forward on approval, so a
// new device reads live group traffic, but it has no re-wrap of historical **1:1**
// message keys. PLAN.md §4.3.3(B) states the consequence plainly: "Prior 1:1
// messages: NOT readable on a newly approved device… A device that did not exist at
// send time has no wrapped key, and the server cannot mint one (it never had the
// plaintext key)."
//
// The server cannot fix this. Only a device that can already open the history can.
// So the OLD device does the work:
//
//   1. `POST /api/chat/handoffs` — the server counts what the target is missing and
//      opens a ledger row.
//   2. `GET  …/pending` — the message ids the target device has no wrapped key for,
//      oldest first.
//   3. For each, the old device opens the content key it already holds and
//      RE-WRAPS it to the new device's X-Wing public key.
//   4. `POST …/batch` — uploaded in batches; the ledger advances; a client that dies
//      mid-transfer picks up from `pending` on the next launch.
//
// **The server never sees a plaintext key** in any step. It counts what is missing
// and stores what comes back, as ordinary `message_recipients` rows — which is why
// the new device then reads history through exactly the same code path as any other
// message, with no special case anywhere in the decrypt path.
//
// # Why history is walked by conversation rather than by id
//
// `pending` returns bare message ids. Deriving a content key needs the message's own
// wrapped key (1:1) or its group key version (group), so a naive implementation
// fetches each message individually — 200 round trips per batch. Instead this pages
// each conversation's history with `?device=<source>`, which returns 50 messages AND
// their wrapped keys per request, and re-wraps the ones in the pending set. Same
// result, two orders of magnitude fewer requests, and it is the same endpoint the
// thread view already uses.
//
// After this runs, the disclosure copy narrows accordingly: history is lost only on
// (a) total device loss, and (b) wiping the old phone BEFORE approving the new one.
// That is what `NewPhoneGuideView` is for.

@Observable
@MainActor
final class HistoryHandoffService {
    static let shared = HistoryHandoffService()

    /// The transfer this device is sending, if any.
    private(set) var outgoing: HandoffStatusResponse?
    /// The transfer this device is receiving, learned from `handoff_progress` frames.
    private(set) var incoming: HandoffStatusResponse?
    private(set) var isTransferring = false
    private(set) var lastError: String?

    /// Resume marker. An interrupted transfer must not restart from zero — the whole
    /// point of the server-side ledger is that it can be picked up.
    private let resumeKey = "fwb.chat.handoff.outgoing"

    private let encryption = ChatEncryptionService.shared
    private let batchSize = 100

    private init() {}

    // MARK: - Outgoing (the OLD, approving device)

    /// Begin — or resume — handing history to a device this member just approved.
    func startOutgoing(source: UUID, target: UUID) async {
        guard !isTransferring else { return }
        isTransferring = true
        lastError = nil
        defer { isTransferring = false }

        do {
            // `startHandoff` is itself resumable server-side: an existing pending or
            // in-progress row for this (source, target) pair is returned rather than
            // a second ledger being opened.
            let handoff = try await ChatAPI.startHandoff(source: source, target: target)
            outgoing = handoff
            UserDefaults.standard.set(handoff.id.uuidString, forKey: resumeKey)
            logger.notice("Handoff \(handoff.id) started: \(handoff.totalMessages) message(s) to re-wrap")

            guard handoff.totalMessages > 0 else {
                UserDefaults.standard.removeObject(forKey: resumeKey)
                return
            }
            try await run(handoff: handoff, source: source, target: target)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            logger.error("Handoff failed: \(String(describing: error))")
        }
    }

    /// Pick up an interrupted transfer at launch.
    func resumeIfNeeded() async {
        guard let raw = UserDefaults.standard.string(forKey: resumeKey),
              let handoffId = UUID(uuidString: raw) else { return }
        guard let status = try? await ChatAPI.handoffStatus(handoffId), !status.isTerminal else {
            UserDefaults.standard.removeObject(forKey: resumeKey)
            return
        }
        await startOutgoing(source: status.sourceDeviceId, target: status.targetDeviceId)
    }

    func cancelOutgoing() async {
        guard let handoff = outgoing else { return }
        _ = try? await ChatAPI.cancelHandoff(handoff.id)
        outgoing = nil
        UserDefaults.standard.removeObject(forKey: resumeKey)
    }

    // MARK: - The transfer

    private func run(handoff: HandoffStatusResponse, source: UUID, target: UUID) async throws {
        // The target device's public keys. It is one of OUR devices, so the list
        // route has it; there is no peer lookup involved.
        await ChatService.shared.refreshMyDevices()
        guard let targetDevice = ChatService.shared.myDevices.first(where: { $0.id == target }) else {
            throw ChatCryptoError.missingDeviceKey
        }

        var remaining = try await collectPendingIds(handoff.id)
        guard !remaining.isEmpty else {
            UserDefaults.standard.removeObject(forKey: resumeKey)
            return
        }

        var batch: [HandoffBatchRequest.WrappedKey] = []

        for conversation in ChatService.shared.conversations {
            if remaining.isEmpty { break }

            var before: Date?
            var hasMore = true
            while hasMore, !remaining.isEmpty {
                let page = try await ChatAPI.history(
                    conversationId: conversation.id, before: before, limit: 50, device: source
                )
                hasMore = page.hasMore
                before = page.nextBefore

                for dto in page.items where remaining.contains(dto.id) {
                    guard let contentKey = await contentKey(for: dto, conversation: conversation) else {
                        // The source device cannot open it either — a message that
                        // predates THIS device, or one wrapped to a since-revoked
                        // device. Nothing to hand over, so drop it from the working
                        // set rather than looping on it forever. The server's ledger
                        // still counts it, so the handoff finishes as "in progress"
                        // rather than "completed"; the UI reports what moved.
                        remaining.remove(dto.id)
                        continue
                    }

                    guard let wrapped = try? await encryption.wrapKey(
                        contentKey,
                        recipientIdentityKeyBase64: targetDevice.identityKey,
                        recipientQuantumKeyBase64: targetDevice.quantumPublicKey,
                        requireQuantum: conversation.requireQuantum
                    ) else {
                        remaining.remove(dto.id)
                        continue
                    }

                    batch.append(HandoffBatchRequest.WrappedKey(
                        messageId: dto.id,
                        encryptedMessageKey: wrapped.wrapped,
                        isQuantumSecure: wrapped.isQuantumSecure
                    ))
                    remaining.remove(dto.id)

                    if batch.count >= batchSize {
                        try await upload(batch, handoffId: handoff.id)
                        batch.removeAll()
                    }
                }

                if page.items.isEmpty { break }
            }
        }

        if !batch.isEmpty { try await upload(batch, handoffId: handoff.id) }

        if outgoing?.isTerminal == true || remaining.isEmpty {
            UserDefaults.standard.removeObject(forKey: resumeKey)
        }
        logger.notice("Handoff \(handoff.id) finished: \(self.outgoing?.deliveredMessages ?? 0)/\(self.outgoing?.totalMessages ?? 0)")
    }

    private func upload(_ keys: [HandoffBatchRequest.WrappedKey], handoffId: UUID) async throws {
        outgoing = try await ChatAPI.uploadHandoffBatch(HandoffBatchRequest(handoffId: handoffId, keys: keys))
    }

    /// Drain every page of `pending` into one set. Bounded by the server's own limit
    /// and by the conversation walk that follows, so a very large history pages
    /// rather than loading unboundedly.
    private func collectPendingIds(_ handoffId: UUID) async throws -> Set<UUID> {
        var ids = Set<UUID>()
        var hasMore = true
        var guardCounter = 0
        while hasMore, guardCounter < 200 {
            guardCounter += 1
            let page = try await ChatAPI.handoffPending(handoffId, limit: 500)
            let before = ids.count
            ids.formUnion(page.messageIds)
            hasMore = page.hasMore
            // The endpoint returns the SAME oldest-first window until keys are
            // uploaded, so a page that adds nothing means we have the whole set and
            // looping again would spin forever.
            if ids.count == before { break }
        }
        return ids
    }

    /// The key that opens a message on the SOURCE device.
    private func contentKey(for dto: ChatMessageDTO, conversation: ChatConversation) async -> SymmetricKey? {
        if let version = dto.groupKeyVersion {
            return await ChatService.shared.groupKeyForHandoff(conversationId: conversation.id, version: version)
        }
        guard let wrapped = dto.encryptedMessageKey else { return nil }
        return try? await encryption.unwrapKey(wrapped, isQuantumSecure: dto.isQuantumSecure)
    }

    // MARK: - Incoming (the NEW device)

    /// Applied on the target device from the `handoff_progress` frame — the one
    /// genuinely device-scoped signal in the whole protocol, which is why the server
    /// routes it `toDevice:` rather than over the conversation fan-out.
    func applyProgressFrame(_ frame: ChatWSFrame) {
        guard let raw = frame.values["handoffId"], let id = UUID(uuidString: raw) else { return }
        let delivered = Int(frame.values["delivered"] ?? "") ?? 0
        let total = Int(frame.values["total"] ?? "") ?? 0
        let status = frame.values["status"] ?? "in_progress"

        incoming = HandoffStatusResponse(
            id: id,
            sourceDeviceId: incoming?.sourceDeviceId ?? id,
            targetDeviceId: incoming?.targetDeviceId ?? id,
            status: status,
            totalMessages: total,
            deliveredMessages: delivered,
            lastMessageAt: nil,
            completedAt: status == "completed" ? Date() : nil
        )

        // Keys have landed as recipient rows. Re-read the open thread so the
        // "Sent before this device was added" placeholders resolve into real
        // messages without the member doing anything.
        Task { await ChatService.shared.reloadAfterHandoff() }
    }

    /// Called right after this device registers. If an old device already uploaded
    /// keys for us, they are simply there — nothing to fetch, only to re-read.
    func drainIncomingIfNeeded(targetDeviceId: UUID) async {
        await ChatService.shared.reloadAfterHandoff()
    }
}

// MARK: - ChatService hooks

extension ChatService {
    /// The group key at a version, for the handoff walk. Exposed rather than
    /// duplicating the fetch-and-unwrap, so there is one place group keys are opened.
    func groupKeyForHandoff(conversationId: UUID, version: Int) async -> SymmetricKey? {
        await groupKeyPublic(conversationId: conversationId, version: version)
    }

    /// Drop the decrypted-message caches and re-read every open thread. Called when
    /// a handoff lands new keys — the cached "no key for this device" verdicts are
    /// now wrong, and nothing else invalidates them.
    func reloadAfterHandoff() async {
        clearMessageKeyCache()
        for conversationId in messagesByConversation.keys {
            await loadMessages(conversationId)
        }
    }
}
