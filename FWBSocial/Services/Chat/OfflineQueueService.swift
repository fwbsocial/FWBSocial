import CryptoKit
import Foundation
import Network
import Observation

// MARK: - Cache crypto
//
// A per-install AES-256 key in the keychain, used to seal anything this app writes
// to disk. Ported from Cove's `CacheCrypto` minus the eviction bookkeeping the
// message cache needed — the outbox is the only consumer here.

nonisolated enum CacheCrypto {
    private static let keyTag = "fwb.chat.cache.key.v1"

    private static func key() throws -> SymmetricKey {
        if let existing = ChatKeychain.load(forKey: keyTag) { return SymmetricKey(data: existing) }
        let fresh = SymmetricKey(size: .bits256)
        let data = fresh.withUnsafeBytes { Data($0) }
        try ChatKeychain.save(data, forKey: keyTag)
        return fresh
    }

    static func seal(_ data: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: try key()).combined else {
            throw ChatCryptoError.encryptionFailed
        }
        return combined
    }

    static func open(_ blob: Data) throws -> Data {
        try AES.GCM.open(try AES.GCM.SealedBox(combined: blob), using: try key())
    }

    /// `completeUntilFirstUserAuthentication` so a background drain after a reboot
    /// can still read it, without leaving plaintext-adjacent bytes readable to a
    /// forensic pull of a powered-off device.
    static func writeProtected(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

// MARK: - Outbox entry

/// A text send awaiting delivery.
///
/// **Plaintext is persisted, never the per-device wrapped keys** — and that is
/// deliberate, not laziness. The drain RE-encrypts and RE-wraps to the recipients'
/// CURRENT devices, so a peer who added or revoked a device between the failure and
/// the retry is handled correctly. Storing the wrapped keys would freeze a stale
/// device set into the retry.
nonisolated struct OutboxEntry: Codable, Identifiable, Sendable {
    var id: UUID { clientMessageId }
    let clientMessageId: UUID
    let conversationId: UUID
    let text: String
    let contentType: String
    let replyToId: UUID?
    /// Stamped at the ORIGINAL send time, so a message queued for an hour still
    /// expires on the schedule the member saw when they sent it.
    let expiresAt: Date?
    let createdAt: Date
    var retryCount: Int = 0
}

// MARK: - Offline queue
//
// Ported from Cove's `OfflineQueueService` (152 LoC). Report 02 calls it
// "crypto-free"; under E2EE that is only true of THIS file — the crypto step lives
// in the consumer's drain callback (`ChatService.drainOutbox` → re-encrypt,
// re-wrap, re-POST), which is exactly where PLAN.md §5.2 says it stays.
//
// The server is idempotent on `client_message_id` (`MessageController.send` returns
// the existing row rather than 409ing), so a retry can NEVER duplicate — even when
// the original send actually landed and only its response was lost.
//
// Scope: TEXT only. A media send would need the blob persisted and orphan
// management for the R2 object, so those surface their error immediately.

@MainActor
@Observable
final class OfflineQueueService {
    static let shared = OfflineQueueService()

    private(set) var queuedCount = 0
    var isSyncing = false
    var isOnline = true

    /// Retry ceiling. Cove shipped `retryCount` that was neither bumped nor
    /// enforced, so a poison entry re-encrypted and re-POSTed on every reconnect
    /// forever. Past the cap the bubble fails and the entry stops draining until the
    /// member retries it by hand.
    static let maxRetries = 10

    private var entries: [OutboxEntry] = []
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "events.fwb.social.netmonitor")

    private var fileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("fwb-chat-outbox.bin")
    }

    private init() {
        startNetworkMonitor()
        Task { await reload() }
    }

    // MARK: - Persistence

    private func reload() async {
        guard let blob = try? Data(contentsOf: fileURL),
              let plaintext = try? CacheCrypto.open(blob),
              let decoded = try? JSONDecoder().decode([OutboxEntry].self, from: plaintext)
        else {
            entries = []
            queuedCount = 0
            return
        }
        entries = decoded
        queuedCount = decoded.count
        if !decoded.isEmpty {
            Task { await ChatService.shared.drainOutbox() }
        }
    }

    private func persist() {
        queuedCount = entries.count
        guard !entries.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let data = try? JSONEncoder().encode(entries),
              let blob = try? CacheCrypto.seal(data) else { return }
        try? CacheCrypto.writeProtected(blob, to: fileURL)
    }

    // MARK: - Queue operations

    /// Idempotent on `clientMessageId`.
    func enqueue(_ entry: OutboxEntry) {
        guard !entries.contains(where: { $0.clientMessageId == entry.clientMessageId }) else { return }
        entries.append(entry)
        persist()
    }

    /// Oldest first, excluding exhausted entries.
    func pending() -> [OutboxEntry] {
        entries.filter { $0.retryCount < Self.maxRetries }.sorted { $0.createdAt < $1.createdAt }
    }

    func remove(clientMessageId: UUID) {
        entries.removeAll { $0.clientMessageId == clientMessageId }
        persist()
    }

    func bumpRetry(clientMessageId: UUID) {
        guard let index = entries.firstIndex(where: { $0.clientMessageId == clientMessageId }) else { return }
        entries[index].retryCount += 1
        persist()
    }

    func isExhausted(clientMessageId: UUID) -> Bool {
        guard let entry = entries.first(where: { $0.clientMessageId == clientMessageId }) else { return false }
        return entry.retryCount >= Self.maxRetries
    }

    /// Sign-out: one account's unsent plaintext must never reach the next member on
    /// this device.
    func clear() {
        entries = []
        queuedCount = 0
        isSyncing = false
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Reachability

    private func startNetworkMonitor() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let online = path.status == .satisfied
                let cameOnline = online && !self.isOnline
                self.isOnline = online
                if cameOnline {
                    // Kick the socket NOW rather than letting it wait out a backoff
                    // that was scheduled while the radio was off.
                    FWBChatSocket.shared.nudgeReconnect()
                    await ChatService.shared.drainOutbox()
                }
            }
        }
        monitor.start(queue: monitorQueue)
    }
}
