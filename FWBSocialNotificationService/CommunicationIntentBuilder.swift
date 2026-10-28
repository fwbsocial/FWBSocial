import Foundation
import Intents
import UserNotifications

// MARK: - Communication-notification intent
//
// Builds the `INSendMessageIntent` that turns a chat banner into a native
// communication notification (sender name + avatar, app name demoted), and applies it
// to the notification content.
//
// # Privacy contract — read before editing
//
// The intent carries the SENDER and the group name ONLY. It never carries message
// text (`content` is nil), and it is NEVER donated to the system.
//
// An earlier version passed the decrypted body as `content` and called
// `INInteraction(intent:response:).donate(completion:)`. A donation writes into the
// system CoreDuet/Interactions store — outside the app container and outside the
// end-to-end-encryption boundary this extension otherwise keeps — and nothing in the
// app ever purged it, so chat plaintext outlived sign-out, message delete/expiry and
// account deletion. Owner decision 2026-10-28: no donation, ever. The decrypted
// body reaches the banner only through `UNMutableNotificationContent.body`, which
// lives in the notification itself and goes away when the notification does.
//
// This file has no dependency on `AppGroupStore` or the app so the unit tests can
// compile it too (see `NotificationIntentTests`); the avatar arrives as a parameter.

nonisolated enum CommunicationIntentBuilder {

    /// The intent used to style the banner. Sender (+ speakable group) only; no text.
    static func makeIntent(
        senderId: String?,
        senderName: String,
        conversationTitle: String?,
        avatar: INImage?
    ) -> INSendMessageIntent {
        let handle = INPersonHandle(value: senderId ?? senderName, type: .unknown)
        let sender = INPerson(
            personHandle: handle,
            nameComponents: nil,
            displayName: senderName,
            image: avatar,
            contactIdentifier: nil,
            customIdentifier: senderId
        )

        // A group carries a speakable name so the banner reads "Sender, Group"; a 1:1
        // omits it — the conversation title there IS the sender's name, and repeating
        // it reads as a bug.
        let speakableGroup = (conversationTitle != senderName)
            ? conversationTitle.map { INSpeakableString(spokenPhrase: $0) }
            : nil

        return INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: nil,                 // never the decrypted body — see header
            speakableGroupName: speakableGroup,
            conversationIdentifier: nil,
            serviceName: nil,
            sender: sender,
            attachments: nil
        )
    }

    /// Apply the sender-only intent to `content` WITHOUT donating it. Returns nil when
    /// the system declines, and the caller falls back to the plain title/subtitle
    /// banner. `content.body` must already be set by the caller; it is left untouched.
    static func upgrade(
        _ content: UNMutableNotificationContent,
        senderId: String?,
        senderName: String,
        conversationTitle: String?,
        avatar: INImage?
    ) -> UNNotificationContent? {
        let intent = makeIntent(
            senderId: senderId, senderName: senderName,
            conversationTitle: conversationTitle, avatar: avatar
        )
        return try? content.updating(from: intent)
    }
}
