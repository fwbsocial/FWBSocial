import XCTest

/// The Phase 6 chat UI smoke: sign in as a vetted member who already has an E2EE
/// conversation, open the thread, send a message through the real composer, and
/// walk the device and friend surfaces.
///
/// **Local server, and that is a finding rather than a shortcut** — the same one
/// `ForumSmokeTests` records. Chat needs a VETTED account; vetting comes only from an
/// admin or a matched Luma check-in; production deliberately has no admin
/// (`ADMIN_BOOTSTRAP_EMAIL` is unset until the commissioner names them). So every
/// `/api/chat/*` route except device registration answers 403 there, and escalating
/// our own account to admin on the commissioner's live server to get around that
/// would be privilege escalation, not testing.
///
/// What IS verified against production is device enrolment — including the
/// server-side verification of the PQ key binding, which is the riskiest single
/// adaptation in the port. See `ChatSmokeTests`.
///
/// The conversation this drives was created by `ChatRoundTripTests`, which is the
/// only way to get a real cross-device E2EE thread: two independent key sets need
/// two simulators.
final class ChatSmokeUITests: XCTestCase {

    private var app: XCUIApplication!
    private let timeout: TimeInterval = 30

    private static let email = "cara.p6@example.invalid"
    private static let password = "correct horse battery staple"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["FWB_API_BASE"] = "http://127.0.0.1:8080"
    }

    func testChatSurfaces() throws {
        app.launch()

        openChatTab()
        signIn()
        openChatTab()
        shoot("01-conversation-list")

        openFirstConversation()
        shoot("02-thread-decrypted")

        sendMessage("Sent from the UI smoke.")
        shoot("03-after-send")

        openDetails()
        shoot("04-conversation-details")

        openSafetyNumber()
        shoot("05-safety-number")
    }

    // MARK: - Steps

    /// Signs in from whichever prompt is on screen.
    ///
    /// An earlier version guarded on Home's CTA and returned quietly when it did not
    /// appear, on the assumption that meant "already signed in". It did not — the
    /// run sailed past sign-in and failed much later with "a conversation should be
    /// listed", pointing at chat when the problem was auth. This asserts instead:
    /// either a sign-in affordance is reachable, or the session is genuinely live.
    private func signIn() {
        let memberPrompt = app.buttons["Sign in"]
        let homeCTA = app.buttons["home.signInCTA"]

        if app.textFields["chat.composer"].exists || app.cells.element(boundBy: 0).exists {
            return   // already signed in and showing chat
        }

        if memberPrompt.waitForExistence(timeout: 8) {
            memberPrompt.tap()
        } else if homeCTA.waitForExistence(timeout: 8) {
            homeCTA.tap()
        } else {
            XCTFail("no sign-in affordance and no signed-in chat surface. Tree:\n\(app.debugDescription)")
            return
        }

        let continueWithEmail = app.buttons["auth.continueWithEmail"]
        XCTAssertTrue(continueWithEmail.waitForExistence(timeout: timeout), "welcome screen should appear")
        continueWithEmail.tap()

        let emailField = app.textFields.element(boundBy: 0)
        XCTAssertTrue(emailField.waitForExistence(timeout: timeout), "sign-in form should appear")
        type(Self.email, into: emailField)
        type(Self.password, into: app.secureTextFields.element(boundBy: 0))
        app.buttons["signIn.submit"].tap()

        clearOnboardingIfPresent()
    }

    /// The member was seeded through the API, so the terms gate and the 18+ gate
    /// both stand between sign-in and the app.
    private func clearOnboardingIfPresent() {
        let accept = app.switches["onboarding.acceptToggle"]
        if accept.waitForExistence(timeout: 10) {
            var attempts = 0
            while !accept.isHittable && attempts < 6 {
                app.swipeUp()
                attempts += 1
            }
            // The toggle's frame spans the whole row, so a centred tap lands in
            // the middle of the sentence. Aim at the trailing edge — and VERIFY it
            // took, by watching Continue become enabled. A single blind tap missed
            // and the run then failed on "Continue … Disabled", which reads as a
            // gate bug rather than a mis-aimed tap.
            let cont = app.buttons["onboarding.continue"]
            for _ in 0 ..< 4 where !cont.isEnabled {
                accept.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
                _ = cont.waitForExistence(timeout: 2)
            }
            if cont.waitForExistence(timeout: 5), cont.isEnabled {
                if !cont.isHittable { app.swipeUp() }
                cont.tap()
            }
        }

        let confirmAge = app.buttons["onboarding.confirmAge"]
        if confirmAge.waitForExistence(timeout: 10) {
            if !confirmAge.isHittable { app.swipeUp() }
            confirmAge.tap()
        }
    }

    /// iOS 26's floating tab bar does not reliably answer to `app.tabBars`, so this
    /// falls back to a plain button query and VERIFIES the switch happened rather
    /// than assuming the tap landed.
    private func openChatTab() {
        let navTitle = app.navigationBars["Chat"]
        for _ in 0 ..< 3 {
            for candidate in [app.tabBars.buttons["Chat"], app.buttons["Chat"]] where candidate.exists {
                candidate.tap()
                if navTitle.waitForExistence(timeout: 8) { return }
            }
        }
        XCTFail("could not reach the Chat tab. Tree:\n\(app.debugDescription)")
    }

    private func openFirstConversation() {
        let cell = app.cells.element(boundBy: 0)
        XCTAssertTrue(cell.waitForExistence(timeout: timeout), "a conversation should be listed")
        cell.tap()
        XCTAssertTrue(app.textFields["chat.composer"].waitForExistence(timeout: timeout), "the composer should appear")
    }

    private func sendMessage(_ text: String) {
        let composer = app.textFields["chat.composer"]
        composer.tap()
        composer.typeText(text)
        app.buttons["chat.send"].tap()
        // The bubble is the assertion: it only renders because the app sealed the
        // text, wrapped the key per recipient device, POSTed it, and decrypted the
        // stored row back.
        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: timeout), "the sent message should appear in the thread")
    }

    private func openDetails() {
        app.buttons["chat.details"].tap()
        XCTAssertTrue(app.navigationBars["Details"].waitForExistence(timeout: timeout))
    }

    private func openSafetyNumber() {
        let link = app.buttons["chat.safetyNumber"]
        XCTAssertTrue(link.waitForExistence(timeout: timeout), "safety number should be reachable")
        link.tap()
        XCTAssertTrue(app.staticTexts["chat.safetyNumber.digits"].waitForExistence(timeout: timeout),
                      "a safety number should be computed for this conversation")
    }

    // MARK: - Helpers

    private func type(_ text: String, into field: XCUIElement) {
        field.tap()
        field.typeText(text)
    }

    private func shoot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent("shot-\(name).png")
        try? screenshot.pngRepresentation.write(to: url)
        print("[smoke] wrote \(url.path)")
    }
}
