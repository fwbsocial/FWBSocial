import Testing
import Foundation
@testable import FWBSocial

// MARK: - End-to-end encrypted round trip
//
// The one thing a single process cannot prove.
//
// An E2EE round trip needs TWO devices with TWO independent key sets, and a device's
// keys live in the keychain. Two accounts in one process share one keychain, so the
// second would either reuse the first's identity (proving nothing) or destroy it
// (making the first undecryptable). So this runs as three ROLES across two
// simulators, each with its own keychain, in order:
//
//   1. `enrolReceiver`  on simulator B — Bob registers a device and stops.
//   2. `send`           on simulator A — Alice enrols, opens a thread, sends.
//   3. `receive`        on simulator B — Bob reads it back and decrypts.
//
// The ORDER is itself an assertion. A 1:1 message is sealed under a fresh key
// wrapped only to the recipient devices that exist AT SEND TIME. If Bob had no
// device yet, Alice's send would wrap to nobody, and `ChatService.send` refuses
// rather than storing a ciphertext no one can open — which is why step 1 is separate
// from step 3 instead of being folded into it.
//
// Driven by environment, because the harness has to sequence the runs:
//
//   FWB_SMOKE=1
//   FWB_SMOKE_BASE=http://127.0.0.1:8080
//   FWB_SMOKE_ROLE=enrolReceiver | send | receive
//   FWB_SMOKE_EMAIL / FWB_SMOKE_PASSWORD
//   FWB_SMOKE_PEER   — the other member's user id (the `send` role only)
//   FWB_SMOKE_TEXT   — the exact plaintext to send and then to expect back
//
// Local, not production: chat needs two VETTED accounts, and production has no admin
// to grant vetting (see `ChatSmokeTests`).

@Suite(.serialized)
struct ChatRoundTripTests {

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }
    private static var role: String? { environment["FWB_SMOKE_ROLE"] }

    // Gated with `.enabled(if:)`, not a `#require` in the body — a failed `#require`
    // fails the test rather than skipping it, which turned every routine
    // `xcodebuild test` red.
    @Test(
        "E2EE round trip: enrol, send, decrypt on the other device",
        .enabled(if: ProcessInfo.processInfo.environment["FWB_SMOKE"] == "1"
                 && ProcessInfo.processInfo.environment["FWB_SMOKE_ROLE"] != nil)
    )
    @MainActor
    func roundTrip() async throws {
        let base = FWBConfig.baseURL
        #expect(base.contains("127.0.0.1") || base.contains("localhost"),
                "the round trip seeds vetted accounts and must not run against production")

        try await signIn()

        switch Self.role {
        case "enrolReceiver": try await enrolReceiver()
        case "send":          try await send()
        case "receive":       try await receive()
        default:              Issue.record("unknown FWB_SMOKE_ROLE")
        }
    }

    // MARK: Roles

    /// The recipient registers a device and does nothing else. Until this row
    /// exists, there is no public key to wrap a message key to.
    private func enrolReceiver() async throws {
        await ChatService.shared.registerDeviceIfNeeded()
        let device = try #require(ChatService.shared.thisDevice)
        #expect(device.isApproved, "device #1 self-approves as the TOFU root")
        #expect(device.bindingVerified)
        print("[smoke] receiver device \(device.id)")
    }

    private func send() async throws {
        let peerRaw = try #require(Self.environment["FWB_SMOKE_PEER"])
        let peer = try #require(UUID(uuidString: peerRaw))
        let text = try #require(Self.environment["FWB_SMOKE_TEXT"])

        await ChatService.shared.registerDeviceIfNeeded()
        #expect(ChatService.shared.enrolmentError == nil, "enrolment error: \(ChatService.shared.enrolmentError ?? "none")")
        #expect(ChatService.shared.thisDevice != nil)

        // §4.4's probe. With `inbox_policy` defaulting to friends_only this is only
        // true because the harness friended them — which is exactly why the friend
        // graph had to ship in the same phase as chat.
        let probe = try #require(await ChatService.shared.canMessage(peer))
        #expect(probe.canMessage, "can-message refused a mutual friend")

        let conversation = try await ChatService.shared.startDirectConversation(with: peer)
        #expect(!conversation.isGroup)
        #expect(conversation.requireQuantum, "require_quantum must default TRUE — fail closed")

        try await ChatService.shared.send(conversationId: conversation.id, text: text)

        let messages = try #require(ChatService.shared.messagesByConversation[conversation.id])
        let sent = try #require(messages.last)
        // The sender wraps to its OWN device too, so its own history survives a
        // cache eviction instead of rendering as a placeholder.
        #expect(sent.decryptedText == text)
        #expect(sent.hasKeyForThisDevice)
        #expect(sent.sendState == .sent)
        print("[smoke] sent \(sent.id) in conversation \(conversation.id)")
    }

    private func receive() async throws {
        let text = try #require(Self.environment["FWB_SMOKE_TEXT"])

        await ChatService.shared.registerDeviceIfNeeded()
        // Re-registration must land on the SAME device row the first role created —
        // the upsert key is (user_id, identity_key) and the identity key is still in
        // this simulator's keychain. If this minted a new device, the message would
        // be wrapped to a device we no longer are, and the assertion below would
        // fail for the most confusing possible reason.
        let devices = try await ChatAPI.myDevices()
        #expect(devices.count == 1, "re-registration created a second device row")

        await ChatService.shared.refreshConversations()
        let conversation = try #require(ChatService.shared.conversations.first, "no conversation arrived")

        await ChatService.shared.loadMessages(conversation.id)
        let messages = try #require(ChatService.shared.messagesByConversation[conversation.id])
        let received = try #require(messages.last, "no message in the conversation")

        // THE assertion: ciphertext fetched from the server, this device's wrapped
        // key unwrapped with its X-Wing private key, body opened with AES-GCM.
        #expect(received.hasKeyForThisDevice, "no wrapped key for this device — the send did not target it")
        #expect(received.decryptedText == text, "decrypted plaintext did not match what was sent")
        #expect(received.isQuantumSecure, "the wrap should be post-quantum, not the classical fallback")
        #expect(received.senderId != UUID(uuidString: AuthService.shared.user?.id ?? ""), "sender should be the peer")

        // Receipts and the badge come from the same server-side predicate, so
        // marking read must move the unread total rather than only a local flag.
        await ChatService.shared.markRead(conversation.id)
        #expect(ChatService.shared.unreadTotal == 0)
        print("[smoke] decrypted: \(received.decryptedText ?? "nil")")
    }

    // MARK: Sign-in

    private func signIn() async throws {
        let email = try #require(Self.environment["FWB_SMOKE_EMAIL"])
        let password = try #require(Self.environment["FWB_SMOKE_PASSWORD"])
        try await AuthService.shared.login(email: email, password: password)
        let user = try #require(AuthService.shared.user)
        #expect(user.isVetted, "the round trip needs a vetted account")
    }
}
