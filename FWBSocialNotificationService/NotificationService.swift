import Foundation
import Intents
import UserNotifications

// MARK: - Notification Service Extension
//
// Ported from Cove's `NotificationService` (384 LoC), pruned of the nudge / mutual /
// reunion branches that die with those features (PLAN.md §8).
//
// # Why this extension has to exist at all
//
// PLAN.md §4.3.5: "The APNs payload carries **metadata only** (conversation id,
// message id, sender id) — it cannot carry a preview, **because the server cannot
// read the message**." That is arithmetic, not a privacy policy the server chooses
// to honour. `ChatPushService` sends `mutable-content: 1` and a deliberately
// uninformative "New message" body; everything a member actually wants to see is
// produced here, on their own device.
//
// The upgrade path:
//   push `message_id` → GET /api/chat/messages/:id?device=<this device> (Bearer)
//   → X-Wing-unwrap this device's copy of the per-message key
//   → AES-GCM-open the sealed body
//   → build an `INSendMessageIntent` so the banner renders as a native
//     communication notification: sender name and avatar, app icon demoted.
//
// Names and avatars come from the App Group, resolved on-device. **Nothing
// identifying ever travels through APNs.**
//
// # Three failure rules, all from §4.3.5
//
//   1. **The network dependency is hard, and a failed fetch must degrade to a
//      generic banner — never a silent drop.** A deploy restarts the server and
//      every in-flight fetch fails (PLAN.md R8); the member still gets a
//      notification, it just says less.
//   2. `hide_message_previews` is enforced HERE, because the server has nothing to
//      redact and this extension cannot read Postgres. The flag is mirrored into the
//      App Group by `ChatService.mirrorPreferences`.
//   3. The budget is roughly 24 MB and 30 s for fetch, unwrap, decrypt and intent
//      building. The fetch timeout is deliberately well inside it, and
//      `serviceExtensionTimeWillExpire` always has a formatted best attempt ready.

/// One-shot, thread-safe delivery of the content handler.
///
/// Both the fetch completion (URLSession's queue) and `serviceExtensionTimeWillExpire`
/// (the system, when the budget runs out first) can try to deliver, but the extension
/// contract requires the handler run EXACTLY once — a second call risks a crash and
/// drops the notification. First caller wins. `@unchecked Sendable` is sound because
/// every access is serialised by the lock.
private final class OneShotDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?

    init(_ handler: @escaping (UNNotificationContent) -> Void) { self.handler = handler }

    func deliver(_ content: UNNotificationContent) {
        lock.lock()
        let handler = self.handler
        self.handler = nil
        lock.unlock()
        handler?(content)
    }
}

final class NotificationService: UNNotificationServiceExtension {

    /// Must match `FWBConfig.baseURL`. Inlined because the extension does not compile
    /// the app's `Config.swift` — if the API host moves, both change together.
    private static let baseURL = "https://api.fwb.events"
    private static let appId = "fwb-ios"

    private var delivery: OneShotDelivery?
    private var bestAttempt: UNNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }

        let info = request.content.userInfo
        let senderId = info["sender_id"] as? String
        let conversationId = info["conversation_id"] as? String
        let messageId = info["message_id"] as? String
        let threadId = request.content.threadIdentifier
        // The server-computed unread total rides in `aps.badge`. The async path
        // rebuilds fresh content for Sendability and would otherwise drop it — and
        // iOS reads a nil badge as "leave the icon alone", not "clear it".
        let pushBadge = request.content.badge?.intValue

        let senderName = senderId.flatMap { AppGroupStore.displayName(forSenderId: $0) }
        let conversationTitle = conversationId.flatMap { AppGroupStore.title(forConversationId: $0) }

        // The member asked for no previews. Ship the server's generic alert as-is —
        // this is the only place the setting can be honoured.
        guard !AppGroupStore.hideMessagePreviews else {
            contentHandler(content)
            return
        }

        guard let messageId,
              let deviceId = ChatMessageDecryptor.deviceId,
              let token = ChatMessageDecryptor.authToken,
              let fetch = Self.fetchRequest(messageId: messageId, deviceId: deviceId, token: token)
        else {
            // No credentials readable (signed out, or pre-first-unlock) → the
            // person-formatted generic banner, immediately.
            contentHandler(Self.buildMessageContent(
                base: content, senderId: senderId, senderName: senderName,
                conversationTitle: conversationTitle, body: "New message"
            ))
            return
        }

        let delivery = OneShotDelivery(contentHandler)
        self.delivery = delivery
        self.bestAttempt = Self.buildMessageContent(
            base: content, senderId: senderId, senderName: senderName,
            conversationTitle: conversationTitle, body: "New message"
        )

        // The completion captures ONLY Sendable values — never the mutable content —
        // and rebuilds fresh content from the captured strings.
        URLSession.shared.dataTask(with: fetch) { data, response, _ in
            let decrypted = Self.decryptFetched(data: data, response: response)
            let fresh = UNMutableNotificationContent()
            fresh.sound = .default
            if !threadId.isEmpty { fresh.threadIdentifier = threadId }
            if let pushBadge { fresh.badge = NSNumber(value: pushBadge) }
            let final = Self.buildMessageContent(
                base: fresh, senderId: senderId, senderName: senderName,
                conversationTitle: conversationTitle,
                body: decrypted.body ?? decrypted.fallback
            )
            delivery.deliver(final)
        }.resume()
    }

    override func serviceExtensionTimeWillExpire() {
        // A no-op if the fetch already delivered — the one-shot drops the second
        // call, so the handler still runs exactly once.
        if let bestAttempt { delivery?.deliver(bestAttempt) }
    }

    // MARK: - Fetch + decrypt

    private static func fetchRequest(messageId: String, deviceId: String, token: String) -> URLRequest? {
        guard let url = URL(string: "\(baseURL)/api/chat/messages/\(messageId)?device=\(deviceId)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(appId, forHTTPHeaderField: "X-App-Id")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private struct DecryptOutcome {
        /// The real message text, when everything worked.
        let body: String?
        /// What to show otherwise — a content-type phrase where we know the type, or
        /// the generic line. Never blank.
        let fallback: String
    }

    /// Decode and decrypt, or fall back. Returns on ANY failure: non-200, a
    /// classical-wrapped message (this extension is quantum-only by construction),
    /// offline, an expired token, a decrypt error. The server returned ciphertext and
    /// this device's wrapped key; no plaintext ever left the device.
    private static func decryptFetched(data: Data?, response: URLResponse?) -> DecryptOutcome {
        guard let data,
              let http = response as? HTTPURLResponse,
              http.statusCode == 200
        else { return DecryptOutcome(body: nil, fallback: "New message") }

        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let message = try decoder.decode(FetchedMessage.self, from: data)
            let phrase = Self.phrase(forContentType: message.contentType)

            // A media message has no readable body worth previewing, and decrypting
            // a thumbnail here is exactly the kind of thing that pushes a PQ unwrap
            // over the memory ceiling (PLAN.md R5).
            guard message.contentType == "text" else {
                return DecryptOutcome(body: nil, fallback: phrase)
            }
            guard let wrapped = message.encryptedMessageKey, message.isQuantumSecure else {
                return DecryptOutcome(body: nil, fallback: phrase)
            }
            let plaintext = try ChatMessageDecryptor.decryptText(
                wrappedKeyBase64: wrapped,
                encryptedContentBase64: message.encryptedContent
            )
            return DecryptOutcome(body: plaintext, fallback: phrase)
        } catch {
            return DecryptOutcome(body: nil, fallback: "New message")
        }
    }

    /// A minimal mirror of `ChatMessageResponse`. snake_case via
    /// `convertFromSnakeCase`, with no explicit `CodingKeys` — writing the snake_case
    /// names here would double-convert them.
    private struct FetchedMessage: Decodable {
        let encryptedContent: String
        let contentType: String
        let isQuantumSecure: Bool
        let encryptedMessageKey: String?
    }

    // MARK: - Content building

    private static func phrase(forContentType type: String) -> String {
        switch type {
        case "image": return "sent a photo"
        case "video": return "sent a video"
        case "audio": return "sent a voice message"
        case "file":  return "sent a file"
        default:      return "New message"
        }
    }

    /// Prefer the native communication notification — sender as an `INPerson`, name
    /// and avatar, app name dropped from the header. Falls back to a plain
    /// title/body when there is no cached name or the system declines.
    private static func buildMessageContent(
        base content: UNMutableNotificationContent,
        senderId: String?,
        senderName: String?,
        conversationTitle: String?,
        body: String
    ) -> UNNotificationContent {
        content.body = body
        if let senderName,
           let upgraded = communicationContent(
               base: content, senderId: senderId, senderName: senderName,
               conversationTitle: conversationTitle, body: body
           ) {
            return upgraded
        }
        content.title = senderName ?? conversationTitle ?? "fwb social"
        if let conversationTitle, conversationTitle != senderName { content.subtitle = conversationTitle }
        return content
    }

    private static func communicationContent(
        base content: UNMutableNotificationContent,
        senderId: String?,
        senderName: String,
        conversationTitle: String?,
        body: String
    ) -> UNNotificationContent? {
        content.body = body

        let handle = INPersonHandle(value: senderId ?? senderName, type: .unknown)
        let sender = INPerson(
            personHandle: handle,
            nameComponents: nil,
            displayName: senderName,
            image: senderId.flatMap(Self.cachedAvatar(forSenderId:)),
            contactIdentifier: nil,
            customIdentifier: senderId
        )

        // A group carries a speakable name so the banner reads "Sender, Group"; a 1:1
        // omits it — the conversation title there IS the sender's name, and repeating
        // it reads as a bug.
        let speakableGroup = (conversationTitle != senderName)
            ? conversationTitle.map { INSpeakableString(spokenPhrase: $0) }
            : nil

        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: body,
            speakableGroupName: speakableGroup,
            conversationIdentifier: nil,
            serviceName: nil,
            sender: sender,
            attachments: nil
        )

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)

        return try? content.updating(from: intent)
    }

    private static func cachedAvatar(forSenderId id: String) -> INImage? {
        guard let data = AppGroupStore.avatarData(forSenderId: id) else { return nil }
        return INImage(imageData: data)
    }
}
