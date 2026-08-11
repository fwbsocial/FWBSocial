import CryptoKit
import Foundation
import Observation
import OSLog
import UIKit
import UserNotifications

private let logger = Logger(subsystem: "events.fwb.social", category: "Chat")

// MARK: - Chat service
//
// The orchestration hub, ported from Cove's `ChatService` (4,142 LoC) with every
// deleted product surface left behind — Off-Grid, P2P, Stash, Direct Link, the Deep
// End, nudges, presence, Reunion, the Watch mirror and the structured composers are
// all out of scope (PLAN.md §4.3.2, §8). What survives is the part that makes E2EE
// chat work: device enrolment, the trust-gated key wrap, group-key distribution,
// decryption, receipts, the offline outbox, and the realtime seam.
//
// # The one rule that shapes everything here
//
// **The server cannot read anything.** It stores ciphertext and per-device wrapped
// keys and it is a courier for blobs the clients wrapped for each other. So every
// operation that looks like it should be one round trip is two: fetch the wrapped
// key, unwrap it locally, then open the body. That is not inefficiency to optimise
// away — it is the product.

@Observable
@MainActor
final class ChatService {
    static let shared = ChatService()

    // MARK: - Observable state

    private(set) var conversations: [ChatConversation] = []
    private(set) var messagesByConversation: [UUID: [ChatMessage]] = [:]
    private(set) var myDevices: [ChatDeviceDTO] = []
    private(set) var unreadTotal = 0

    /// This device's row, once registered. Nil means enrolment has not run or
    /// failed — every send path checks it, because a message needs a
    /// `sender_device_id` the server will accept.
    private(set) var thisDevice: ChatDeviceDTO?

    /// Set when `PUT /api/chat/devices` reported `is_root` — this registration
    /// self-promoted to the trust root (§4.3.3(A)). Drives the onboarding copy that
    /// explains what that means.
    private(set) var thisDeviceIsRoot = false

    /// Per-conversation trust notes from the last wrap. Blocking entries mean a
    /// device was skipped and its owner cannot read that message on it.
    private(set) var securityWarnings: [UUID: [DeviceTrustWarning]] = [:]

    /// Peers whose safety number changed and who need explicit re-acceptance.
    private(set) var pendingKeyChanges: [UUID: [ChatDeviceDTO]] = [:]

    /// Typing indicators, scoped BY CONVERSATION. A flat set would show "Alex is
    /// typing" in the thread you have open because Alex is typing in a different
    /// one — the frame carries a conversation id precisely so it doesn't have to.
    private(set) var typingByConversation: [UUID: Set<UUID>] = [:]
    private(set) var isLoadingConversations = false
    private(set) var hasMoreByConversation: [UUID: Bool] = [:]

    /// Display names for everyone we have seen, so the list and the thread can label
    /// a sender without a lookup per row. Also the source for the App Group mirror
    /// the NSE reads.
    private(set) var displayNames: [UUID: String] = [:]

    /// The banner the Chat tab shows when device enrolment failed outright.
    private(set) var enrolmentError: String?

    // MARK: - Private state

    private let encryption = ChatEncryptionService.shared
    private var realtimeTask: Task<Void, Never>?
    private var typingClearTask: Task<Void, Never>?

    /// Decrypted group keys, `conversationId → version → key`. In memory only: an
    /// on-disk copy would be a second place group keys live, and the fetch is cheap.
    private var groupKeys: [UUID: [Int: SymmetricKey]] = [:]

    /// Short-TTL peer device cache. A send wraps to every member's devices, so
    /// without this a group send is one round trip per member per message.
    private var peerDeviceCache: [UUID: (devices: [ChatDeviceDTO], fetchedAt: Date)] = [:]
    private let peerDeviceCacheTTL: TimeInterval = 120

    /// Per-message content keys we have already unwrapped, so scrolling history back
    /// and forth does not re-run HPKE on every row.
    private var messageKeyCache: [UUID: SymmetricKey] = [:]

    private var currentUserId: UUID? {
        AuthService.shared.user.flatMap { UUID(uuidString: $0.id) }
    }

    /// This device's chat device id, preferring the in-memory row and falling back to
    /// the keychain. A separate method rather than `thisDevice?.id ?? (await …)`
    /// because `??`'s right side is an autoclosure and cannot be awaited.
    private func resolvedDeviceId() async -> UUID? {
        if let id = thisDevice?.id { return id }
        return await encryption.deviceId()
    }

    private init() {}

    // MARK: - Session lifecycle

    /// Called after a session is established. Enrols this device, starts realtime and
    /// loads the conversation list.
    ///
    /// Device enrolment deliberately runs for a `pending` member too:
    /// `PUT /api/chat/devices` sits OUTSIDE the vetting gate (§4.6) precisely so the
    /// TOFU root is minted at first login, and the moment vetting flips their chat
    /// simply works with no re-enrolment.
    func start() async {
        guard AuthService.shared.isSignedIn else { return }
        await registerDeviceIfNeeded()
        mirrorPreferences()
        guard AuthService.shared.user?.isVetted == true else { return }
        await startRealtime()
        await refreshConversations()
        await refreshUnreadCount()
    }

    /// Sign-out.
    ///
    /// **Key material is deliberately NOT destroyed here.** PLAN.md §4.3.3(C)
    /// records Cove's logout keychain churn as an inherited known defect, not a
    /// hypothetical: deleting the device keys on sign-out meant signing back in on
    /// the SAME device minted a fresh identity, stranded the previous device row as
    /// an unapprovable orphan, and sealed every prior message to keys that no longer
    /// existed. The TOFU re-root bounded the blast radius, but it did so by
    /// destroying history — a data-loss outcome, not a graceful one.
    ///
    /// The fix is to stop doing it. Signing out drops the session and every decrypted
    /// byte in memory and on disk; the identity, signing and X-Wing keys stay in the
    /// keychain, so signing back in re-registers the SAME `identity_key`, hits the
    /// server's `(user_id, identity_key)` upsert, and lands on the same still-approved
    /// device row with history intact. Account deletion is the path that destroys
    /// keys, and it revokes the device rows server-side in the same breath.
    func handleSignOut() {
        realtimeTask?.cancel()
        realtimeTask = nil
        FWBChatSocket.shared.disconnect()
        conversations = []
        messagesByConversation = [:]
        myDevices = []
        thisDevice = nil
        thisDeviceIsRoot = false
        securityWarnings = [:]
        pendingKeyChanges = [:]
        displayNames = [:]
        groupKeys = [:]
        peerDeviceCache = [:]
        messageKeyCache = [:]
        unreadTotal = 0
        enrolmentError = nil
        OfflineQueueService.shared.clear()
        AppGroupStore.clear()
        Task { await encryption.clearKeyCache() }
    }

    /// Account deletion only — the server is revoking every device row anyway, and
    /// leaving private keys on the device after that would be the wrong trade.
    func destroyLocalKeyMaterial() async {
        await encryption.destroyAllKeys()
        await DeviceTrustStore.shared.clearAll()
        handleSignOut()
    }

    // MARK: - Device enrolment

    /// Register (or re-register) this device.
    ///
    /// Idempotent by construction: the server's upsert key is
    /// `(user_id, identity_key)` and the identity key is stable in the keychain, so
    /// calling this on every launch reconciles rather than proliferating rows.
    func registerDeviceIfNeeded() async {
        do {
            let identityKey = try await encryption.identityPublicKeyBase64()
            let signingKey = try await encryption.signingPublicKeyBase64()
            let quantumKey = try await encryption.generateQuantumKeyPairIfNeeded()

            // The classical↔PQ binding. fwb-server VERIFIES this — a signature over
            // the wrong bytes is a 400, not a silent downgrade.
            guard let payload = ChatEncryptionService.keyBindingSignaturePayload(
                quantumPublicKeyBase64: quantumKey
            ) else { throw ChatCryptoError.encodingFailed }
            let keySignature = try await encryption.sign(payload).base64EncodedString()

            let registered = try await ChatAPI.registerDevice(RegisterDeviceRequest(
                deviceName: UIDevice.current.name,
                platform: "ios",
                identityKey: identityKey,
                signingPublicKey: signingKey,
                quantumPublicKey: quantumKey,
                keySignature: keySignature,
                enrolledByDeviceId: nil,
                approvalSignature: nil
            ))

            try await encryption.storeDeviceId(registered.id)
            thisDevice = registered
            thisDeviceIsRoot = registered.isRoot
            enrolmentError = nil
            logger.notice("Device enrolled: \(registered.id) (root: \(registered.isRoot), approved: \(registered.isApproved))")

            await refreshMyDevices()

            // A newly approved device drains any handoff the old device started.
            if registered.isApproved {
                await HistoryHandoffService.shared.drainIncomingIfNeeded(targetDeviceId: registered.id)
            }
        } catch {
            enrolmentError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            logger.error("Device enrolment failed: \(String(describing: error))")
        }
    }

    func refreshMyDevices() async {
        guard let devices = try? await ChatAPI.myDevices() else { return }
        myDevices = devices
        if let mine = await resolvedDeviceId(),
           let updated = devices.first(where: { $0.id == mine }) {
            // The list route always reports `is_root: false`; keep the flag the
            // registration response gave us rather than clobbering it.
            thisDevice = updated
        }
    }

    /// Devices awaiting approval from this one. The approving device must itself be
    /// approved and active, which the server enforces.
    var pendingDevices: [ChatDeviceDTO] {
        myDevices.filter { !$0.isApproved && $0.isActive && $0.id != thisDevice?.id }
    }

    /// Approve another of this member's devices, then hand over history (A2).
    ///
    /// The approval signature is made by THIS device's signing key over the target's
    /// identity key. The server stores it without verifying — deliberately: the trust
    /// decision belongs to the device, and the server holds no key that could check
    /// it.
    func approveDevice(_ device: ChatDeviceDTO) async throws {
        guard let approver = thisDevice, approver.isUsable else {
            throw ChatCryptoError.missingDeviceKey
        }
        let payload = ChatEncryptionService.deviceApprovalSignaturePayload(
            identityKeyBase64: device.identityKey
        )
        let signature = try await encryption.sign(payload).base64EncodedString()

        _ = try await ChatAPI.approveDevice(device.id, body: ApproveDeviceRequest(
            approvalSignature: signature,
            approvedByDeviceId: approver.id
        ))
        await refreshMyDevices()

        // Forward: re-wrap every group key this device holds to the new one, so the
        // new device can read live group traffic straight away.
        await grantAllGroupKeys(to: device)

        // Backward: PLAN-ADDENDUM A2. The owner's expectation is that approving a new
        // device from a still-live old one preserves full history, and Cove as
        // shipped does not do that for 1:1 threads.
        await HistoryHandoffService.shared.startOutgoing(source: approver.id, target: device.id)
    }

    func revokeDevice(_ device: ChatDeviceDTO) async throws {
        try await ChatAPI.revokeDevice(device.id)
        await DeviceTrustStore.shared.forget(device.id)
        await refreshMyDevices()
    }

    // MARK: - Realtime

    func startRealtime() async {
        guard realtimeTask == nil || !FWBChatSocket.shared.isLive else { return }
        realtimeTask?.cancel()

        let deviceId = await resolvedDeviceId()
        let stream = FWBChatSocket.shared.connect(deviceId: deviceId)

        // Delivery frames are fire-and-forget server-side: anything sent while the
        // socket was down is simply gone. A reconnect therefore refetches rather
        // than assuming continuity.
        FWBChatSocket.shared.onReconnect = { [weak self] in
            Task { await self?.refreshConversations() }
        }

        realtimeTask = Task { [weak self] in
            for await frame in stream {
                await self?.handle(frame)
            }
        }
    }

    private func handle(_ frame: ChatWSFrame) async {
        switch frame.type {
        case ChatWSType.message:
            guard let dto = frame.message else { return }
            await ingest(dto)

        case ChatWSType.typing:
            guard let senderId = frame.senderId, senderId != currentUserId,
                  let conversationId = frame.conversationId else { return }
            if frame.values["isTyping"] == "false" {
                typingByConversation[conversationId]?.remove(senderId)
            } else {
                typingByConversation[conversationId, default: []].insert(senderId)
                scheduleTypingClear(senderId, in: conversationId)
            }

        case ChatWSType.read, ChatWSType.delivered:
            // Refresh the aggregate rather than guessing at it — the server derives
            // delivered/read counts from the recipient rows and the client has no
            // independent view of another member's devices.
            if let conversationId = frame.conversationId {
                await refreshTail(conversationId)
            }

        case ChatWSType.reaction:
            if let conversationId = frame.conversationId,
               let raw = frame.values["messageId"], let messageId = UUID(uuidString: raw) {
                await refreshOne(messageId, in: conversationId)
            }

        case ChatWSType.deleted:
            if let conversationId = frame.conversationId,
               let raw = frame.values["messageId"], let messageId = UUID(uuidString: raw) {
                messagesByConversation[conversationId]?.removeAll { $0.id == messageId }
            }

        case ChatWSType.deviceAdded:
            // Either one of OUR devices enrolled, or a peer's did. Both invalidate
            // the cached device sets: the next message must wrap to the new device.
            peerDeviceCache.removeAll()
            await refreshMyDevices()

        case ChatWSType.deviceRevoked:
            peerDeviceCache.removeAll()
            await refreshMyDevices()

        case ChatWSType.handoffProgress:
            HistoryHandoffService.shared.applyProgressFrame(frame)

        default:
            break
        }
    }

    /// A typing frame has no "stopped" guarantee — the sender may background the
    /// app mid-word — so the indicator self-expires rather than waiting for a frame
    /// that may never arrive.
    private func scheduleTypingClear(_ userId: UUID, in conversationId: UUID) {
        typingClearTask?.cancel()
        typingClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.typingByConversation[conversationId]?.remove(userId)
        }
    }

    /// Who is typing in a conversation right now, excluding us.
    func typingMembers(in conversationId: UUID) -> [UUID] {
        Array(typingByConversation[conversationId] ?? []).filter { $0 != currentUserId }
    }

    // MARK: - Conversations

    func refreshConversations() async {
        isLoadingConversations = true
        defer { isLoadingConversations = false }
        do {
            let dtos = try await ChatAPI.conversations()
            conversations = dtos.map(ChatConversation.init(dto:))
            await learnNames(for: conversations)
            mirrorConversationTitles()
            await refreshUnreadCount()
        } catch {
            logger.error("Conversation list failed: \(String(describing: error))")
        }
    }

    func refreshUnreadCount() async {
        guard let response = try? await ChatAPI.unreadCount() else { return }
        unreadTotal = response.total
        UNUserNotificationCenterBadge.set(response.total)
    }

    /// `can-message` before offering a Message button. The response shape is
    /// identical for every refusal — do not try to render a reason from it.
    func canMessage(_ userId: UUID) async -> CanMessageResponse? {
        try? await ChatAPI.canMessage(userId: userId)
    }

    /// Start (or reuse) a 1:1. The server returns the existing thread rather than
    /// forking history in two.
    func startDirectConversation(with userId: UUID) async throws -> ChatConversation {
        let dto = try await ChatAPI.createConversation(CreateConversationRequest(
            isGroup: false,
            title: nil,
            participantIds: [userId],
            requireQuantum: true
        ))
        let conversation = ChatConversation(dto: dto)
        upsert(conversation)
        return conversation
    }

    func createGroup(title: String?, memberIds: [UUID]) async throws -> ChatConversation {
        let dto = try await ChatAPI.createConversation(CreateConversationRequest(
            isGroup: true,
            title: title,
            participantIds: memberIds,
            requireQuantum: true
        ))
        let conversation = ChatConversation(dto: dto)
        upsert(conversation)
        // The creator mints and distributes the first group key — nobody else can,
        // and until it exists the group cannot carry a message.
        _ = try? await ensureGroupKey(for: conversation)
        return conversation
    }

    func addMembers(_ userIds: [UUID], to conversationId: UUID) async throws {
        let dto = try await ChatAPI.addMembers(conversationId, userIds: userIds)
        let conversation = ChatConversation(dto: dto)
        upsert(conversation)
        // The server bumped `current_group_key_version`; the actor who caused the
        // change is the one who mints and distributes the replacement.
        await rotateGroupKey(for: conversation)
    }

    func removeMember(_ userId: UUID, from conversationId: UUID) async throws {
        let dto = try await ChatAPI.removeMember(conversationId, userId: userId)
        let conversation = ChatConversation(dto: dto)
        upsert(conversation)
        // Rotate so the removed member's key does not open what comes next. Their
        // wrapped keys for this conversation were already deleted server-side.
        await rotateGroupKey(for: conversation)
    }

    func leave(_ conversationId: UUID) async throws {
        guard let me = currentUserId else { return }
        _ = try? await ChatAPI.removeMember(conversationId, userId: me)
        conversations.removeAll { $0.id == conversationId }
        messagesByConversation[conversationId] = nil
    }

    func setMuted(_ muted: Bool, conversationId: UUID) async {
        // "Muted" is a far-future `muted_until`; unmuting is the distant past. The
        // server models a timestamp, not a flag, so the client speaks that language.
        let until = muted ? Date().addingTimeInterval(60 * 60 * 24 * 3650) : Date(timeIntervalSince1970: 0)
        guard let dto = try? await ChatAPI.updateConversation(
            conversationId,
            body: UpdateConversationRequest(title: nil, disappearingSeconds: nil, clearDisappearing: nil, mutedUntil: until)
        ) else { return }
        upsert(ChatConversation(dto: dto))
    }

    func setTitle(_ title: String, conversationId: UUID) async throws {
        let dto = try await ChatAPI.updateConversation(
            conversationId,
            body: UpdateConversationRequest(title: title, disappearingSeconds: nil, clearDisappearing: nil, mutedUntil: nil)
        )
        upsert(ChatConversation(dto: dto))
    }

    /// The per-conversation message-TTL override (30 / 90 / 365 / off).
    func setMessageTTL(_ ttl: MessageTTL, conversationId: UUID) async throws {
        let dto = try await ChatAPI.updateConversation(
            conversationId,
            body: UpdateConversationRequest(
                title: nil,
                disappearingSeconds: ttl.seconds,
                clearDisappearing: ttl == .off ? true : nil,
                mutedUntil: nil
            )
        )
        upsert(ChatConversation(dto: dto))
    }

    func conversation(_ id: UUID) -> ChatConversation? {
        conversations.first { $0.id == id }
    }

    private func upsert(_ conversation: ChatConversation) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        } else {
            conversations.insert(conversation, at: 0)
        }
        conversations.sort { ($0.lastMessageAt ?? $0.createdAt ?? .distantPast) > ($1.lastMessageAt ?? $1.createdAt ?? .distantPast) }
    }

    // MARK: - Messages

    func loadMessages(_ conversationId: UUID) async {
        let deviceId = await resolvedDeviceId()
        do {
            let page = try await ChatAPI.history(conversationId: conversationId, limit: 50, device: deviceId)
            let decrypted = await decrypt(page.items, conversationId: conversationId)
            messagesByConversation[conversationId] = decrypted.sorted { $0.createdAt < $1.createdAt }
            hasMoreByConversation[conversationId] = page.hasMore
        } catch {
            logger.error("History failed for \(conversationId): \(String(describing: error))")
        }
    }

    /// Older page. Returns false when there is nothing more, so the scroll view can
    /// stop asking.
    @discardableResult
    func loadOlderMessages(_ conversationId: UUID) async -> Bool {
        guard hasMoreByConversation[conversationId] != false,
              let oldest = messagesByConversation[conversationId]?.first?.createdAt else { return false }
        let deviceId = await resolvedDeviceId()
        do {
            let page = try await ChatAPI.history(
                conversationId: conversationId, before: oldest, limit: 50, device: deviceId
            )
            let decrypted = await decrypt(page.items, conversationId: conversationId)
            var existing = messagesByConversation[conversationId] ?? []
            let known = Set(existing.map(\.id))
            existing.insert(contentsOf: decrypted.filter { !known.contains($0.id) }, at: 0)
            messagesByConversation[conversationId] = existing.sorted { $0.createdAt < $1.createdAt }
            hasMoreByConversation[conversationId] = page.hasMore
            return page.hasMore
        } catch {
            return false
        }
    }

    private func refreshTail(_ conversationId: UUID) async {
        let deviceId = await resolvedDeviceId()
        guard let page = try? await ChatAPI.history(conversationId: conversationId, limit: 30, device: deviceId) else { return }
        let decrypted = await decrypt(page.items, conversationId: conversationId)
        merge(decrypted, into: conversationId)
    }

    private func refreshOne(_ messageId: UUID, in conversationId: UUID) async {
        let deviceId = await resolvedDeviceId()
        guard let dto = try? await ChatAPI.message(messageId, device: deviceId) else { return }
        let decrypted = await decrypt([dto], conversationId: conversationId)
        merge(decrypted, into: conversationId)
    }

    private func ingest(_ dto: ChatMessageDTO) async {
        let decrypted = await decrypt([dto], conversationId: dto.conversationId)
        merge(decrypted, into: dto.conversationId)

        if var conversation = conversation(dto.conversationId) {
            conversation.lastMessageAt = dto.createdAt ?? Date()
            if dto.senderId != currentUserId { conversation.unreadCount += 1 }
            upsert(conversation)
        } else {
            await refreshConversations()
        }
        await refreshUnreadCount()

        // Acknowledge delivery so the sender's ticks move without a second REST
        // write path into the durable read state.
        if dto.senderId != currentUserId {
            await FWBChatSocket.shared.send(.delivered(dto.conversationId, messageId: dto.id))
        }
    }

    private func merge(_ incoming: [ChatMessage], into conversationId: UUID) {
        var existing = messagesByConversation[conversationId] ?? []
        for message in incoming {
            // Collapse the optimistic copy: the local echo and the stored row share
            // a `clientMessageId`, which is what stops a send rendering twice.
            if let index = existing.firstIndex(where: { $0.id == message.id || $0.clientMessageId == message.clientMessageId }) {
                var merged = message
                // Keep locally-known plaintext: a sender's own message is never
                // wrapped to its own device in a group, so re-decrypting it from the
                // server would produce nothing.
                if merged.decryptedText == nil, let known = existing[index].decryptedText {
                    merged.decryptedText = known
                }
                existing[index] = merged
            } else {
                existing.append(message)
            }
        }
        messagesByConversation[conversationId] = existing
            .filter { !$0.isExpired }
            .sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Decryption

    private func decrypt(_ dtos: [ChatMessageDTO], conversationId: UUID) async -> [ChatMessage] {
        var out: [ChatMessage] = []
        for dto in dtos {
            let key = await contentKey(for: dto)
            var text: String?
            if let key {
                text = try? await encryption.open(dto.encryptedContent, with: key)
            }
            out.append(ChatMessage(dto: dto, decrypted: text, hasKey: key != nil))
        }
        return out
    }

    /// The symmetric key that opens a message body.
    ///
    /// Two paths, and which one applies is decided by whether the message names a
    /// group key version:
    ///   • group  → the group key at that version, fetched or minted once.
    ///   • 1:1    → this device's wrapped copy from `encrypted_message_key`.
    ///
    /// A nil return is not necessarily an error: history that predates this device
    /// has no wrapped key for it, which is §4.3.3(B) working as designed and what
    /// A2's handoff exists to repair.
    private func contentKey(for dto: ChatMessageDTO) async -> SymmetricKey? {
        if let cached = messageKeyCache[dto.id] { return cached }

        if let version = dto.groupKeyVersion {
            guard let key = await groupKey(conversationId: dto.conversationId, version: version) else { return nil }
            messageKeyCache[dto.id] = key
            return key
        }

        guard let wrapped = dto.encryptedMessageKey else { return nil }
        guard let key = try? await encryption.unwrapKey(wrapped, isQuantumSecure: dto.isQuantumSecure) else {
            logger.error("Unwrap failed for message \(dto.id)")
            return nil
        }
        messageKeyCache[dto.id] = key
        return key
    }

    // MARK: - Group keys

    /// Every version this device holds for a conversation, decrypted into memory.
    private func loadGroupKeys(_ conversationId: UUID) async {
        guard let deviceId = await resolvedDeviceId(),
              let rows = try? await ChatAPI.groupKeys(conversationId: conversationId, device: deviceId)
        else { return }

        var keys = groupKeys[conversationId] ?? [:]
        for row in rows where keys[row.keyVersion] == nil {
            // A group key is wrapped exactly like a message key. `require_quantum`
            // defaults TRUE, so try the PQ unwrap first and fall back — the row does
            // not carry a quantum flag of its own.
            if let key = try? await encryption.unwrapKey(row.encryptedGroupKey, isQuantumSecure: true) {
                keys[row.keyVersion] = key
            } else if let key = try? await encryption.unwrapKey(row.encryptedGroupKey, isQuantumSecure: false) {
                keys[row.keyVersion] = key
            }
        }
        groupKeys[conversationId] = keys
    }

    private func groupKey(conversationId: UUID, version: Int) async -> SymmetricKey? {
        if let key = groupKeys[conversationId]?[version] { return key }
        await loadGroupKeys(conversationId)
        return groupKeys[conversationId]?[version]
    }

    /// The same lookup, reachable from `HistoryHandoffService` — so group keys are
    /// fetched and unwrapped in exactly one place.
    func groupKeyPublic(conversationId: UUID, version: Int) async -> SymmetricKey? {
        await groupKey(conversationId: conversationId, version: version)
    }

    /// Invalidate the per-message key cache. Its "no key for this device" verdicts
    /// go stale the moment a handoff lands new recipient rows, and nothing else
    /// clears them.
    func clearMessageKeyCache() { messageKeyCache.removeAll() }

    /// The key for the CURRENT version, minting and distributing one if nobody has.
    ///
    /// The mint-on-demand path is a fallback, not the normal route: whoever created
    /// the group or changed its membership distributes immediately (`createGroup`,
    /// `addMembers`, `removeMember`). It exists so a member whose distribution POST
    /// failed can still send, and so a conversation cannot deadlock waiting for a
    /// key nobody produced.
    @discardableResult
    private func ensureGroupKey(for conversation: ChatConversation) async throws -> SymmetricKey {
        if let key = await groupKey(conversationId: conversation.id, version: conversation.groupKeyVersion) {
            return key
        }
        let key = await encryption.generateContentKey()
        try await distribute(key, version: conversation.groupKeyVersion, for: conversation)
        groupKeys[conversation.id, default: [:]][conversation.groupKeyVersion] = key
        return key
    }

    private func rotateGroupKey(for conversation: ChatConversation) async {
        let key = await encryption.generateContentKey()
        do {
            try await distribute(key, version: conversation.groupKeyVersion, for: conversation)
            groupKeys[conversation.id, default: [:]][conversation.groupKeyVersion] = key
        } catch {
            logger.error("Group key rotation failed for \(conversation.id): \(String(describing: error))")
        }
    }

    /// Wrap a group key once per device of every current member and upload the set.
    /// The server refuses entries for devices that are not a current member's, which
    /// is what stops a caller silently adding a reader.
    private func distribute(_ key: SymmetricKey, version: Int, for conversation: ChatConversation) async throws {
        var entries: [UploadGroupKeysRequest.GroupKeyEntry] = []
        var warnings: [DeviceTrustWarning] = []

        for memberId in conversation.memberIds {
            for device in await usableDevices(of: memberId) {
                let decision = await wrapDecision(for: device, requireQuantum: conversation.requireQuantum)
                switch decision {
                case .skip(let warning):
                    warnings.append(warning)
                    continue
                case .wrap(let warning):
                    if let warning { warnings.append(warning) }
                }
                guard let wrapped = try? await encryption.wrapKey(
                    key,
                    recipientIdentityKeyBase64: device.identityKey,
                    recipientQuantumKeyBase64: device.quantumPublicKey,
                    requireQuantum: conversation.requireQuantum
                ) else {
                    warnings.append(DeviceTrustWarning(
                        deviceId: device.id, deviceName: device.deviceName,
                        ownerId: device.userId, kind: .quantumRequiredButMissing
                    ))
                    continue
                }
                entries.append(.init(deviceId: device.id, encryptedGroupKey: wrapped.wrapped))
            }
        }

        securityWarnings[conversation.id] = warnings.isEmpty ? nil : warnings
        guard !entries.isEmpty else { throw ChatCryptoError.noUsableRecipientDevices }
        try await ChatAPI.uploadGroupKeys(
            conversationId: conversation.id,
            body: UploadGroupKeysRequest(keyVersion: version, keys: entries)
        )
    }

    /// Re-wrap every group key we hold to a newly approved device of our own, so it
    /// can read live group traffic immediately. Messages under earlier versions stay
    /// readable too, because every version we hold is granted — not just the current
    /// one.
    private func grantAllGroupKeys(to device: ChatDeviceDTO) async {
        for conversation in conversations where conversation.isGroup {
            await loadGroupKeys(conversation.id)
            guard let versions = groupKeys[conversation.id], !versions.isEmpty else { continue }
            for (version, key) in versions {
                guard let wrapped = try? await encryption.wrapKey(
                    key,
                    recipientIdentityKeyBase64: device.identityKey,
                    recipientQuantumKeyBase64: device.quantumPublicKey,
                    requireQuantum: conversation.requireQuantum
                ) else { continue }
                try? await ChatAPI.uploadGroupKeys(
                    conversationId: conversation.id,
                    body: UploadGroupKeysRequest(
                        keyVersion: version,
                        keys: [.init(deviceId: device.id, encryptedGroupKey: wrapped.wrapped)]
                    )
                )
            }
        }
    }

    // MARK: - Peer devices and the trust gate

    private func usableDevices(of userId: UUID) async -> [ChatDeviceDTO] {
        if let cached = peerDeviceCache[userId], Date().timeIntervalSince(cached.fetchedAt) < peerDeviceCacheTTL {
            return cached.devices
        }
        // Our own devices come from the list route; a peer's come from the gated
        // peer route, which 403s without a shared conversation.
        let devices: [ChatDeviceDTO]
        if userId == currentUserId {
            devices = myDevices.filter(\.isUsable)
        } else {
            devices = (try? await ChatAPI.peerDevices(userId: userId))?.filter(\.isUsable) ?? []
        }
        peerDeviceCache[userId] = (devices, Date())
        return devices
    }

    func invalidatePeerDeviceCache() { peerDeviceCache.removeAll() }

    private enum WrapDecision {
        case wrap(warning: DeviceTrustWarning?)
        case skip(warning: DeviceTrustWarning)
    }

    /// Evaluate one recipient device: TOFU + signature, then the quantum policy.
    /// Fail-closed at every branch.
    private func wrapDecision(for device: ChatDeviceDTO, requireQuantum: Bool) async -> WrapDecision {
        // OUR OWN sending device is implicitly trusted — we hold its private keys —
        // and must always be wrapped. Running peer TOFU on it wrongly skips it after
        // a re-registration, and a message wrapped to nobody is unreadable by
        // everyone including us.
        if device.id == thisDevice?.id { return .wrap(warning: nil) }

        switch await DeviceTrustStore.shared.evaluate(device) {
        case .signatureInvalid:
            return .skip(warning: DeviceTrustWarning(
                deviceId: device.id, deviceName: device.deviceName, ownerId: device.userId, kind: .signatureInvalid
            ))
        case .securityCodeChanged:
            return .skip(warning: DeviceTrustWarning(
                deviceId: device.id, deviceName: device.deviceName, ownerId: device.userId, kind: .securityCodeChanged
            ))
        case .newDeviceForKnownPeer:
            guard !device.quantumPublicKey.isEmpty || !requireQuantum else {
                return .skip(warning: DeviceTrustWarning(
                    deviceId: device.id, deviceName: device.deviceName, ownerId: device.userId,
                    kind: .quantumRequiredButMissing
                ))
            }
            return .wrap(warning: DeviceTrustWarning(
                deviceId: device.id, deviceName: device.deviceName, ownerId: device.userId, kind: .newDevice
            ))
        case .trusted, .firstContact:
            break
        }

        guard !device.quantumPublicKey.isEmpty || !requireQuantum else {
            return .skip(warning: DeviceTrustWarning(
                deviceId: device.id, deviceName: device.deviceName, ownerId: device.userId,
                kind: .quantumRequiredButMissing
            ))
        }
        return .wrap(warning: nil)
    }

    /// Wrap a per-message key to every usable device of every member — including our
    /// own, so the sender can re-read its own messages from the server after a cache
    /// eviction rather than seeing a placeholder.
    private func buildRecipientKeys(
        for conversation: ChatConversation,
        messageKey: SymmetricKey
    ) async throws -> [SendMessageRequest.RecipientKey] {
        var recipients: [SendMessageRequest.RecipientKey] = []
        var warnings: [DeviceTrustWarning] = []
        var keyChanged: [ChatDeviceDTO] = []
        var seen = Set<UUID>()

        for memberId in conversation.memberIds {
            for device in await usableDevices(of: memberId) where seen.insert(device.id).inserted {
                switch await wrapDecision(for: device, requireQuantum: conversation.requireQuantum) {
                case .skip(let warning):
                    warnings.append(warning)
                    if warning.kind == .securityCodeChanged { keyChanged.append(device) }
                    continue
                case .wrap(let warning):
                    if let warning { warnings.append(warning) }
                }

                do {
                    let wrapped = try await encryption.wrapKey(
                        messageKey,
                        recipientIdentityKeyBase64: device.identityKey,
                        recipientQuantumKeyBase64: device.quantumPublicKey,
                        requireQuantum: conversation.requireQuantum
                    )
                    recipients.append(SendMessageRequest.RecipientKey(
                        deviceId: device.id,
                        userId: device.userId,
                        encryptedMessageKey: wrapped.wrapped,
                        isQuantumSecure: wrapped.isQuantumSecure
                    ))
                } catch {
                    // One device failing must skip that device, not abort the send.
                    warnings.append(DeviceTrustWarning(
                        deviceId: device.id, deviceName: device.deviceName,
                        ownerId: device.userId, kind: .quantumRequiredButMissing
                    ))
                }
            }
        }

        securityWarnings[conversation.id] = warnings.isEmpty ? nil : warnings
        pendingKeyChanges[conversation.id] = keyChanged.isEmpty ? nil : keyChanged
        return recipients
    }

    // MARK: - Sending

    static let maxMessageLength = 8000

    /// Send a message.
    ///
    /// A 1:1 seals the body under a FRESH per-message key wrapped ONLY to the
    /// recipients computed here. If every device is skipped, the key is wrapped to
    /// nobody and the message is permanently undecryptable by everyone — including
    /// the sender. So an empty recipient set REFUSES the send rather than storing a
    /// ciphertext nobody can open. Groups legitimately send an empty set: the devices
    /// already hold the group key.
    func send(
        conversationId: UUID,
        text: String,
        contentType: ChatMessage.ContentType = .text,
        mediaData: Data? = nil,
        mediaMimeType: String? = nil,
        replyToId: UUID? = nil
    ) async throws {
        guard let conversation = conversation(conversationId) else { throw ChatCryptoError.noKeyForMessage }
        guard let senderDeviceId = await resolvedDeviceId() else {
            throw ChatCryptoError.missingDeviceKey
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || mediaData != nil else { return }
        guard trimmed.count <= Self.maxMessageLength else {
            throw APIError.httpError(413, message: "That message is too long.")
        }

        // 1. Content key.
        let messageKey: SymmetricKey
        var groupKeyVersion: Int?
        if conversation.isGroup {
            messageKey = try await ensureGroupKey(for: conversation)
            groupKeyVersion = conversation.groupKeyVersion
        } else {
            messageKey = await encryption.generateContentKey()
        }

        // 2. Seal the body into ONE base64 blob: nonce ‖ ciphertext ‖ tag.
        let encryptedContent = try await encryption.seal(text, with: messageKey)

        // 3. Media — encrypted client-side under the SAME key, uploaded straight to
        //    R2 so the bytes never transit the API server's 1 GB of RAM.
        var mediaObjectKey: String?
        var mediaThumbKey: String?
        var mediaMetadata: MessageMediaMetadata?
        if let mediaData {
            let sealed = try await encryption.sealMedia(mediaData, with: messageKey)
            let presign = try await ChatAPI.mediaUploadURL(
                conversationId: conversationId,
                contentType: "application/octet-stream",
                byteSize: sealed.count,
                needsThumbnail: false
            )
            try await ChatAPI.uploadToPresignedURL(presign.uploadUrl, data: sealed, contentType: "application/octet-stream")
            mediaObjectKey = presign.objectKey
            mediaThumbKey = presign.thumbObjectKey
            mediaMetadata = MessageMediaMetadata(
                width: nil, height: nil, durationSeconds: nil,
                byteSize: mediaData.count, mimeType: mediaMimeType
            )
        }

        // 4. Wrap per recipient device (1:1 only).
        var recipients: [SendMessageRequest.RecipientKey] = []
        if !conversation.isGroup {
            recipients = try await buildRecipientKeys(for: conversation, messageKey: messageKey)
            guard !recipients.isEmpty else {
                // A refusal may mean our cached device view diverged from the server
                // (the peer re-registered or rotated). Drop it so a retry refetches.
                invalidatePeerDeviceCache()
                throw ChatCryptoError.noUsableRecipientDevices
            }
        }

        let clientMessageId = UUID()
        let expiresAt = conversation.disappearingSeconds.map { Date().addingTimeInterval(TimeInterval($0)) }

        let request = SendMessageRequest(
            encryptedContent: encryptedContent,
            contentType: contentType.rawValue,
            clientMessageId: clientMessageId,
            senderDeviceId: senderDeviceId,
            groupKeyVersion: groupKeyVersion,
            isQuantumSecure: recipients.allSatisfy { $0.isQuantumSecure == true },
            replyToId: replyToId,
            mediaObjectKey: mediaObjectKey,
            mediaThumbKey: mediaThumbKey,
            mediaMetadata: mediaMetadata,
            expiresAt: expiresAt,
            recipientKeys: recipients
        )

        do {
            let stored = try await ChatAPI.send(conversationId: conversationId, body: request)
            messageKeyCache[stored.id] = messageKey
            var local = ChatMessage(dto: stored, decrypted: text, hasKey: true)
            local.sendState = .sent
            merge([local], into: conversationId)
            var updated = conversation
            updated.lastMessageAt = local.createdAt
            upsert(updated)
            Task { await drainOutbox() }
        } catch let error where Self.isOfflineError(error) && contentType == .text && mediaData == nil {
            // Offline: persist the PLAINTEXT for retry and show the bubble as
            // pending. The drain re-encrypts and re-wraps to the recipients' CURRENT
            // devices with the SAME clientMessageId — server-idempotent, so it can
            // never double-send.
            OfflineQueueService.shared.enqueue(OutboxEntry(
                clientMessageId: clientMessageId,
                conversationId: conversationId,
                text: text,
                contentType: contentType.rawValue,
                replyToId: replyToId,
                expiresAt: expiresAt,
                createdAt: Date()
            ))
            appendPending(clientMessageId: clientMessageId, conversationId: conversationId, text: text, replyToId: replyToId)
        }
    }

    private func appendPending(clientMessageId: UUID, conversationId: UUID, text: String, replyToId: UUID?) {
        guard let me = currentUserId, let deviceId = thisDevice?.id else { return }
        let placeholder = ChatMessage(
            id: clientMessageId,
            conversationId: conversationId,
            senderId: me,
            senderDeviceId: deviceId,
            clientMessageId: clientMessageId,
            contentType: .text,
            createdAt: Date(),
            expiresAt: nil,
            editedAt: nil,
            replyToId: replyToId,
            groupKeyVersion: nil,
            isQuantumSecure: true,
            mediaObjectKey: nil,
            mediaThumbKey: nil,
            mediaMetadata: nil,
            decryptedText: text,
            hasKeyForThisDevice: true,
            deliveredCount: 0,
            readCount: 0,
            reactions: [:],
            sendState: .pending
        )
        messagesByConversation[conversationId, default: []].append(placeholder)
    }

    private static func isOfflineError(_ error: Error) -> Bool {
        if case APIError.networkError = error { return true }
        if let urlError = error as? URLError {
            return [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost]
                .contains(urlError.code)
        }
        return false
    }

    /// Replay the outbox. Each entry is RE-encrypted and RE-wrapped to the current
    /// device set — that is why the queue stores plaintext and not wrapped keys.
    func drainOutbox() async {
        let queue = OfflineQueueService.shared
        guard queue.isOnline, !queue.isSyncing else { return }
        let pending = queue.pending()
        guard !pending.isEmpty else { return }

        queue.isSyncing = true
        defer { queue.isSyncing = false }

        for entry in pending {
            guard let conversation = conversation(entry.conversationId),
                  let senderDeviceId = thisDevice?.id else {
                queue.bumpRetry(clientMessageId: entry.clientMessageId)
                continue
            }
            do {
                let messageKey: SymmetricKey
                var groupKeyVersion: Int?
                if conversation.isGroup {
                    messageKey = try await ensureGroupKey(for: conversation)
                    groupKeyVersion = conversation.groupKeyVersion
                } else {
                    messageKey = await encryption.generateContentKey()
                }
                let sealed = try await encryption.seal(entry.text, with: messageKey)
                var recipients: [SendMessageRequest.RecipientKey] = []
                if !conversation.isGroup {
                    recipients = try await buildRecipientKeys(for: conversation, messageKey: messageKey)
                    guard !recipients.isEmpty else { throw ChatCryptoError.noUsableRecipientDevices }
                }

                let stored = try await ChatAPI.send(
                    conversationId: entry.conversationId,
                    body: SendMessageRequest(
                        encryptedContent: sealed,
                        contentType: entry.contentType,
                        clientMessageId: entry.clientMessageId,
                        senderDeviceId: senderDeviceId,
                        groupKeyVersion: groupKeyVersion,
                        isQuantumSecure: recipients.allSatisfy { $0.isQuantumSecure == true },
                        replyToId: entry.replyToId,
                        mediaObjectKey: nil,
                        mediaThumbKey: nil,
                        mediaMetadata: nil,
                        expiresAt: entry.expiresAt,
                        recipientKeys: recipients
                    )
                )
                messageKeyCache[stored.id] = messageKey
                queue.remove(clientMessageId: entry.clientMessageId)
                merge([ChatMessage(dto: stored, decrypted: entry.text, hasKey: true)], into: entry.conversationId)
            } catch where Self.isOfflineError(error) {
                // Still offline. Leave it queued without burning a retry — the
                // ceiling exists for poison entries, not for a flat radio.
                return
            } catch {
                queue.bumpRetry(clientMessageId: entry.clientMessageId)
                if queue.isExhausted(clientMessageId: entry.clientMessageId) {
                    markFailed(clientMessageId: entry.clientMessageId, conversationId: entry.conversationId)
                }
            }
        }
    }

    private func markFailed(clientMessageId: UUID, conversationId: UUID) {
        guard let index = messagesByConversation[conversationId]?
            .firstIndex(where: { $0.clientMessageId == clientMessageId }) else { return }
        messagesByConversation[conversationId]?[index].sendState = .failed
    }

    /// Retry a bubble the member tapped. Resets the ceiling — an explicit retry is a
    /// new decision, not a continuation of the automatic ones.
    func retry(_ message: ChatMessage) async {
        OfflineQueueService.shared.remove(clientMessageId: message.clientMessageId)
        messagesByConversation[message.conversationId]?.removeAll { $0.clientMessageId == message.clientMessageId }
        guard let text = message.decryptedText else { return }
        try? await send(conversationId: message.conversationId, text: text, replyToId: message.replyToId)
    }

    // MARK: - Receipts, typing, reactions

    func markRead(_ conversationId: UUID) async {
        guard let last = messagesByConversation[conversationId]?.last else { return }
        guard let response = try? await ChatAPI.markSeen(conversationId: conversationId, lastReadMessageId: last.id) else { return }
        unreadTotal = response.total
        UNUserNotificationCenterBadge.set(response.total)
        if var conversation = conversation(conversationId) {
            conversation.unreadCount = 0
            upsert(conversation)
        }
    }

    func sendTyping(_ conversationId: UUID, isTyping: Bool) async {
        await FWBChatSocket.shared.send(.typing(conversationId, isTyping: isTyping))
    }

    func react(to messageId: UUID, emoji: String, in conversationId: UUID) async {
        // Optimistic toggle so the tap lands instantly; the server's echo reconciles.
        if let index = messagesByConversation[conversationId]?.firstIndex(where: { $0.id == messageId }),
           let me = currentUserId {
            var reactions = messagesByConversation[conversationId]![index].reactions
            var users = reactions[emoji] ?? []
            if let existing = users.firstIndex(of: me) { users.remove(at: existing) } else { users.append(me) }
            reactions[emoji] = users.isEmpty ? nil : users
            messagesByConversation[conversationId]![index].reactions = reactions
        }
        try? await ChatAPI.react(messageId: messageId, emoji: emoji)
    }

    func deleteMessage(_ message: ChatMessage) async throws {
        try await ChatAPI.deleteMessage(message.id)
        messagesByConversation[message.conversationId]?.removeAll { $0.id == message.id }
    }

    // MARK: - Media

    /// Fetch and decrypt a message's media. The seam Cove used is correct as written
    /// under E2EE — the object in R2 is ciphertext and the content key is the same
    /// one that opened the body.
    func decryptMedia(for message: ChatMessage) async throws -> Data {
        guard let key = messageKeyCache[message.id] else { throw ChatCryptoError.noKeyForMessage }
        let urls = try await ChatAPI.mediaDownloadURL(messageId: message.id)
        let ciphertext = try await ChatAPI.downloadFromPresignedURL(urls.downloadUrl)
        return try await encryption.openMedia(ciphertext, with: key)
    }

    // MARK: - Safety numbers

    /// The conversation's safety number over every participating device's identity
    /// key, plus whether the member already verified THIS exact number.
    func safetyNumber(for conversationId: UUID) async -> (number: String?, deviceCount: Int, isVerified: Bool) {
        guard let conversation = conversation(conversationId) else { return (nil, 0, false) }
        var identityKeys: [String] = []
        for memberId in conversation.memberIds {
            for device in await usableDevices(of: memberId) { identityKeys.append(device.identityKey) }
        }
        guard let number = SafetyNumber.string(forIdentityKeysBase64: identityKeys) else {
            return (nil, identityKeys.count, false)
        }
        let verified = await DeviceTrustStore.shared.isVerified(
            conversationId: conversationId, currentSafetyNumber: number
        )
        return (number, identityKeys.count, verified)
    }

    func setSafetyNumberVerified(_ verified: Bool, conversationId: UUID, safetyNumber: String) async {
        await DeviceTrustStore.shared.setVerified(verified, conversationId: conversationId, safetyNumber: safetyNumber)
    }

    /// Accept a changed device after an out-of-band check, then clear the block.
    func acceptKeyChange(_ device: ChatDeviceDTO, conversationId: UUID) async {
        await DeviceTrustStore.shared.acceptKeyChange(for: device)
        pendingKeyChanges[conversationId]?.removeAll { $0.id == device.id }
        if pendingKeyChanges[conversationId]?.isEmpty == true { pendingKeyChanges[conversationId] = nil }
        securityWarnings[conversationId]?.removeAll { $0.deviceId == device.id }
        invalidatePeerDeviceCache()
    }

    // MARK: - App Group mirror
    //
    // PLAN.md §4.3.5: `hide_message_previews` is enforced CLIENT-SIDE in the NSE,
    // because the server holds ciphertext and has nothing to redact — and the NSE
    // cannot read the Postgres column. Without this write path the column is inert
    // and the setting silently does nothing. Called on session restore and from the
    // settings toggle, which are the two paths §4.3.5 names.

    func mirrorPreferences() {
        AppGroupStore.hideMessagePreviews = AuthService.shared.user?.hideMessagePreviews ?? false
    }

    private func learnNames(for conversations: [ChatConversation]) async {
        // Friends are the reliable source of a display name: the conversation DTO
        // carries member IDs but no names, and there is no member-lookup endpoint
        // (commissioner decision 9 removed member search entirely).
        guard let friends = try? await FriendsAPI.friends() else { return }
        for friend in friends { displayNames[friend.userId] = friend.displayName }
        if let me = currentUserId, let name = AuthService.shared.user?.displayName {
            displayNames[me] = name
        }
        AppGroupStore.mergeSenderNames(
            Dictionary(uniqueKeysWithValues: displayNames.map { ($0.key.uuidString, $0.value) })
        )
    }

    private func mirrorConversationTitles() {
        var titles: [String: String] = [:]
        for conversation in conversations {
            if let title = conversation.title {
                titles[conversation.id.uuidString] = title
            } else if let me = currentUserId,
                      let other = conversation.otherMemberId(me: me),
                      let name = displayNames[other] {
                // A 1:1 has no server-side title; the peer's name is the honest one.
                titles[conversation.id.uuidString] = name
            }
        }
        AppGroupStore.mergeConversationTitles(titles)
    }

    /// A conversation's label for the list and the thread header.
    func title(for conversation: ChatConversation) -> String {
        if let title = conversation.title, !title.isEmpty { return title }
        guard let me = currentUserId else { return "Conversation" }
        if conversation.isGroup {
            let names = conversation.memberIds.filter { $0 != me }.compactMap { displayNames[$0] }
            return names.isEmpty ? "Group" : names.joined(separator: ", ")
        }
        guard let other = conversation.otherMemberId(me: me) else { return "You" }
        return displayNames[other] ?? "Member"
    }

    func name(for userId: UUID) -> String {
        if userId == currentUserId { return "You" }
        return displayNames[userId] ?? "Member"
    }

    func isMine(_ message: ChatMessage) -> Bool { message.senderId == currentUserId }
}

// MARK: - Badge

/// The app icon badge, driven by the server-computed unread total so the badge and
/// the thread list can never disagree — both come from `UnreadCountService`'s single
/// predicate.
@MainActor
enum UNUserNotificationCenterBadge {
    static func set(_ count: Int) {
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(count) }
    }
}
