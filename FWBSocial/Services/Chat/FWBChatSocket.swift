import Foundation
import OSLog

private let logger = Logger(subsystem: "events.fwb.social", category: "ChatSocket")

// MARK: - Chat WebSocket
//
// Ported near-verbatim from Cove's `CommuneSocket` (380 LoC) — report 02 calls it
// "the strongest portable file in the codebase", and nothing in it is
// Commune-specific except the URL and the token source. Kept intact: the
// delegate-driven `isConnected`, exponential backoff with jitter, the
// token-refresh heuristic after repeated failed handshakes, the 25 s ping, the
// parked-sender continuation, and the `onReconnect` gap-fill hook.
//
// Deleted with the Off-Grid/relay surfaces (PLAN.md §4.3.2): the separate
// `session`-signal stream and its frame-type peek. FWB has no device-targeted
// `.signal` frames — §1.3 verified the per-device Redis channel died with the
// relay — so every frame decodes as one envelope.
//
// # What the socket is for
//
// Ephemera and a live echo. `POST /api/chat/conversations/:id/messages` is the
// write path, because a message needs its per-recipient key rows written in the
// same transaction and a socket frame has no transaction to join. A `message` frame
// carries the full row so the thread can render it without a round-trip, but the
// durable copy already exists before the frame is sent.
//
// # Auth
//
// The handshake carries the bearer token as a QUERY PARAMETER, because
// `URLSessionWebSocketTask` cannot set an `Authorization` header on the upgrade in
// every configuration. `ChatWebSocketController.authenticate` verifies it before
// granting the upgrade — and refuses banned or unvetted members, matching the REST
// gate — so an unauthenticated socket never exists.

@MainActor
final class FWBChatSocket {
    static let shared = FWBChatSocket()

    private(set) var isConnected = false

    /// True while a `connect()` stream is live and we still want the connection.
    /// The socket may be momentarily task-less mid-backoff; its own reconnect
    /// handles that. NOT the same as `isConnected`, which reflects a completed
    /// handshake — callers use this to avoid tearing down a live socket on every
    /// chat open.
    var isLive: Bool { shouldStayConnected && continuation != nil }

    private var task: URLSessionWebSocketTask?
    private lazy var session = URLSession(
        configuration: .default,
        delegate: SocketOpenDelegate(),
        delegateQueue: nil
    )
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var receiveLoopActive = false

    /// Backoff: 1, 2, 4, 8 … capped at 30 s, ±20 % jitter at use. Reset ONLY on a
    /// REAL open — resetting on every attempt let a flapping server be hammered at
    /// 1 s forever. The jitter matters because a deploy drops every client at once
    /// and identical backoffs stampede the comeback in waves (PLAN.md R8).
    private var reconnectDelay: TimeInterval = 1
    private let maxReconnectDelay: TimeInterval = 30

    /// Consecutive reconnects that produced no completed handshake. Past the
    /// threshold the access token is assumed expired — the `?token=` handshake is
    /// being rejected — and refreshed before the next attempt. Without this an idle
    /// foreground app with no REST traffic to trigger a 401-refresh reuses the same
    /// stale token forever while draining battery on the backoff loop.
    private var consecutiveOpenFailures = 0
    private let openFailuresBeforeRefresh = 2

    private var shouldStayConnected = false
    private var deviceId: UUID?
    private var continuation: AsyncStream<ChatWSFrame>.Continuation?

    /// Fires when a handshake completes on a RECONNECT, not the initial connect.
    /// Delivery frames are fire-and-forget server-side, so anything sent during an
    /// outage is simply gone — `ChatService` uses this to refetch.
    var onReconnect: (@MainActor () -> Void)?

    private var didConnectBefore = false

    /// Senders parked waiting for an open socket. Resumed on handshake, on
    /// disconnect (no point waiting), and by a per-waiter watchdog so a long backoff
    /// cannot strand a sender forever.
    private var openWaiters: [OpenWaiter] = []

    /// The flag makes `resume()` idempotent — a continuation must resume exactly
    /// once, and open / disconnect / watchdog can race.
    private final class OpenWaiter {
        private var continuation: CheckedContinuation<Void, Never>?
        init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
        func resume() { continuation?.resume(); continuation = nil }
    }

    private init() {}

    // MARK: - Lifecycle

    /// Open the socket and return the inbound frame stream. A second call tears down
    /// the prior connection and starts fresh — which is what a token refresh needs,
    /// since the token is in the URL.
    func connect(deviceId: UUID?) -> AsyncStream<ChatWSFrame> {
        disconnect(resetIntent: false)
        self.deviceId = deviceId
        shouldStayConnected = true
        didConnectBefore = false

        let stream = AsyncStream<ChatWSFrame> { continuation in
            self.continuation = continuation
            continuation.onTermination = { @Sendable _ in
                Task { @MainActor in self.disconnect() }
            }
        }
        openTask()
        return stream
    }

    /// Tear down. By default this also clears the "want a connection" intent so no
    /// reconnect fires; pass `resetIntent: false` for an internal teardown that
    /// precedes an immediate reopen.
    func disconnect(resetIntent: Bool = true) {
        if resetIntent { shouldStayConnected = false }
        pingTask?.cancel(); pingTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        receiveLoopActive = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
        for waiter in openWaiters { waiter.resume() }   // never strand a parked sender
        openWaiters.removeAll()
        if resetIntent {
            continuation?.finish()
            continuation = nil
        }
    }

    // MARK: - Connection

    private func openTask() {
        guard let token = APIClient.shared.accessToken else { return }

        guard var components = URLComponents(string: FWBConfig.baseURL + "/api/chat/ws") else { return }
        // http(s) → ws(s). The base URL is the single indirection point for
        // dev/prod, so deriving rather than duplicating it keeps them from drifting.
        components.scheme = (components.scheme == "http") ? "ws" : "wss"
        var query = [URLQueryItem(name: "token", value: token)]
        if let deviceId { query.append(URLQueryItem(name: "device", value: deviceId.uuidString)) }
        components.queryItems = query
        guard let url = components.url else { return }

        logger.debug("Opening socket (device: \(self.deviceId?.uuidString ?? "none"))")

        var request = URLRequest(url: url)
        request.setValue(FWBConfig.appId, forHTTPHeaderField: "X-App-Id")
        request.timeoutInterval = 30

        let task = session.webSocketTask(with: request)
        self.task = task
        receiveLoopActive = true
        task.resume()
        // NOT `isConnected = true` here: the handshake has not completed. The
        // delegate's `didOpenWithProtocol` flips it truthfully.
        startPing()
        receiveNext()
    }

    /// The handshake actually completed.
    fileprivate func handleOpened() {
        isConnected = true
        reconnectDelay = 1
        consecutiveOpenFailures = 0
        let wasReconnect = didConnectBefore
        didConnectBefore = true
        for waiter in openWaiters { waiter.resume() }
        openWaiters.removeAll()
        logger.debug("Socket open (handshake complete)")
        if wasReconnect { onReconnect?() }
    }

    fileprivate func handleClosed() { handleDrop() }

    /// The network just came back (`OfflineQueueService`'s path monitor). If we want
    /// a connection and are sitting out a backoff, reconnect NOW rather than waiting
    /// it out.
    func nudgeReconnect() {
        guard shouldStayConnected, task == nil else { return }
        reconnectTask?.cancel(); reconnectTask = nil
        reconnectDelay = 1
        logger.debug("Came-online nudge — reconnecting now")
        openTask()
    }

    private func receiveNext() {
        guard let task, receiveLoopActive else { return }
        task.receive { [weak self] result in
            // Off-main callback. `ChatWSFrame` is nonisolated-Decodable so it decodes
            // safely here; we re-enter the MainActor only to yield.
            switch result {
            case .success(let message):
                let data: Data?
                switch message {
                case .string(let text): data = text.data(using: .utf8)
                case .data(let raw): data = raw
                @unknown default: data = nil
                }
                let decoded = Self.decode(data)
                Task { @MainActor in
                    if let decoded { self?.continuation?.yield(decoded) }
                    self?.receiveNext()
                }
            case .failure:
                Task { @MainActor in self?.handleDrop() }
            }
        }
    }

    /// Decoded on URLSession's queue, off the main actor, so a burst of frames never
    /// queues behind a view update. A local decoder rather than `FWBJSON.decoder`:
    /// that one is MainActor-isolated under the target's default isolation, and
    /// hopping to the main actor just to parse would defeat the point. The strategy
    /// is identical — snake_case keys, ISO8601 dates — and `WireContractTests` pins
    /// the server side of it.
    nonisolated private static func decode(_ data: Data?) -> ChatWSFrame? {
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ChatWSFrame.self, from: data)
    }

    // MARK: - Keepalive

    private func startPing() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled, let self, let task = self.task else { return }
                task.sendPing { [weak self] error in
                    if error != nil {
                        Task { @MainActor in self?.handleDrop() }
                    }
                }
            }
        }
    }

    // MARK: - Reconnect

    private func handleDrop() {
        guard shouldStayConnected else { return }
        isConnected = false
        receiveLoopActive = false
        pingTask?.cancel(); pingTask = nil
        task = nil

        reconnectTask?.cancel()
        let delay = reconnectDelay * Double.random(in: 0.8 ... 1.2)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.shouldStayConnected else { return }
            self.reconnectDelay = min(self.maxReconnectDelay, self.reconnectDelay * 2)

            self.consecutiveOpenFailures += 1
            if self.consecutiveOpenFailures >= self.openFailuresBeforeRefresh {
                _ = await AuthService.shared.refresh()
                self.consecutiveOpenFailures = 0
                // A dead-session refresh signs the member out, which flips
                // `shouldStayConnected`. Don't reopen if so.
                guard !Task.isCancelled, self.shouldStayConnected else { return }
            }
            self.openTask()
        }
    }

    // MARK: - Outbound

    /// Ephemeral signals only. A send fired right after (re)login races the
    /// reconnect and the socket can be momentarily task-less mid-backoff, so the
    /// sender is PARKED on a continuation rather than dropped — resumed on the
    /// handshake, on disconnect, or by a 10 s watchdog (a typing indicator later than
    /// that is stale anyway).
    func send(_ frame: OutboundWSFrame) async {
        if task == nil, shouldStayConnected {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let waiter = OpenWaiter(continuation)
                openWaiters.append(waiter)
                Task {
                    try? await Task.sleep(for: .seconds(10))
                    waiter.resume()
                }
            }
        }
        guard let task else { return }
        guard let data = try? FWBJSON.encoder.encode(frame),
              let json = String(data: data, encoding: .utf8) else { return }
        do {
            try await task.send(.string(json))
        } catch {
            logger.debug("Socket send failed (\(frame.type)): \(error.localizedDescription)")
        }
    }
}

// MARK: - Open/close delegate

/// Bridges `URLSessionWebSocketDelegate` open/close onto the socket, so
/// `isConnected` is set when the HANDSHAKE completes rather than when `resume()` is
/// called. The open event is also what releases parked senders. URLSession calls
/// from its own queue, so every callback hops to the MainActor.
private final class SocketOpenDelegate: NSObject, URLSessionWebSocketDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor in FWBChatSocket.shared.handleOpened() }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { @MainActor in FWBChatSocket.shared.handleClosed() }
    }
}
