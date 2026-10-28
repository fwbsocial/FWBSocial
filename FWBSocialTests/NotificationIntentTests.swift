import Testing
import Foundation
import Intents
import UserNotifications

// MARK: - Notification Service Extension: intent privacy contract
//
// Owner decision 2026-10-28 (follow-up 688E7D6E): the NSE must never write the
// decrypted chat body into the system Interactions store. That store sits outside
// the app container, outside the E2EE boundary, and nothing purges it — so the
// guarantee is "the intent carries the sender only, and is never donated".
//
// `CommunicationIntentBuilder` is compiled into this bundle directly (the NSE is not
// importable); `NotificationService.swift` itself is only READ, as text, for the
// no-donation guard.

@Suite("NSE communication intent")
struct NotificationIntentTests {

    private static let secret = "the decrypted plaintext of a private message"

    @Test("The intent never carries message text")
    func intentHasNoContent() {
        let intent = CommunicationIntentBuilder.makeIntent(
            senderId: "sender-1", senderName: "Alex", conversationTitle: "Trip", avatar: nil
        )
        #expect(intent.content == nil)
    }

    @Test("The intent identifies the sender")
    func intentCarriesSender() throws {
        let intent = CommunicationIntentBuilder.makeIntent(
            senderId: "sender-1", senderName: "Alex", conversationTitle: "Trip", avatar: nil
        )
        let sender = try #require(intent.sender)
        #expect(sender.displayName == "Alex")
        #expect(sender.customIdentifier == "sender-1")
        #expect(sender.personHandle?.value == "sender-1")
    }

    @Test("A missing sender id falls back to the display name as the handle")
    func handleFallsBackToName() {
        let intent = CommunicationIntentBuilder.makeIntent(
            senderId: nil, senderName: "Alex", conversationTitle: nil, avatar: nil
        )
        #expect(intent.sender?.personHandle?.value == "Alex")
        #expect(intent.sender?.customIdentifier == nil)
    }

    @Test("A group conversation gets a speakable name; a 1:1 does not")
    func groupNameOnlyForGroups() {
        let group = CommunicationIntentBuilder.makeIntent(
            senderId: "s", senderName: "Alex", conversationTitle: "Trip", avatar: nil
        )
        #expect(group.speakableGroupName?.spokenPhrase == "Trip")

        let oneToOne = CommunicationIntentBuilder.makeIntent(
            senderId: "s", senderName: "Alex", conversationTitle: "Alex", avatar: nil
        )
        #expect(oneToOne.speakableGroupName == nil)

        let untitled = CommunicationIntentBuilder.makeIntent(
            senderId: "s", senderName: "Alex", conversationTitle: nil, avatar: nil
        )
        #expect(untitled.speakableGroupName == nil)
    }

    @Test("Upgrading works without any donation and leaves the body untouched")
    func upgradeKeepsBodyWithoutDonation() throws {
        let content = UNMutableNotificationContent()
        content.body = Self.secret
        let upgraded = try #require(
            CommunicationIntentBuilder.upgrade(
                content, senderId: "sender-1", senderName: "Alex",
                conversationTitle: "Trip", avatar: nil
            ),
            "content.updating(from:) must succeed for a sender-only intent that was never donated"
        )
        #expect(upgraded.body == Self.secret)
    }

    @Test("Nothing in the extension donates an interaction")
    func extensionSourceNeverDonates() throws {
        // …/FWBSocialTests/NotificationIntentTests.swift → repo root.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let files = ["NotificationService.swift", "CommunicationIntentBuilder.swift"]
            .map { root.appendingPathComponent("FWBSocialNotificationService/\($0)") }

        for url in files {
            let source = try String(contentsOf: url, encoding: .utf8)
            // Comments explain the history and are allowed to say the words.
            let code = source.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            #expect(!code.contains("INInteraction"), "\(url.lastPathComponent) must not use INInteraction")
            #expect(!code.contains("donate("), "\(url.lastPathComponent) must not donate")
        }
    }
}
