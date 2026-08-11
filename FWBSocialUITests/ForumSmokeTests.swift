import XCTest

/// The Phase 4 forum smoke: sign in as a **vetted** member, browse a channel,
/// post, comment, react, report someone else's post, delete your own post.
///
/// **Runs against a LOCAL server, not production, and that is a finding rather
/// than a shortcut.** fwb-server's own `HANDOFF.md` records that the Phase 5
/// smoke ended by deleting the temporary bootstrap admin and unsetting
/// `ADMIN_BOOTSTRAP_EMAILS`. Vetting is granted only by an admin or by a matched
/// Luma check-in, so with no admin on production there is **no member-reachable
/// path to a vetted account** — every `/api/channels/*` route answers 403, and
/// the forum cannot be exercised there at all. Escalating our own account to
/// admin on the commissioner's production server to get around that would be
/// privilege escalation, not testing.
///
/// So this drives `http://localhost:8080` with a seeded admin, two channels and
/// a vetted member. That exercises the real client against the real server
/// binary and the real Postgres schema — everything except the deployment.
/// The production contract is separately verified by curl (see the evidence
/// directory), which is what proved the wire shapes these screens decode.
///
/// Screenshots are attached with `.keepAlways` so they survive a passing run and
/// can be pulled out of the `.xcresult` bundle afterwards.
final class ForumSmokeTests: XCTestCase {

    private var app: XCUIApplication!
    private let timeout: TimeInterval = 30

    private static let email = "p4member@example.invalid"
    private static let password = "correct horse battery staple"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()

        addUIInterruptionMonitor(withDescription: "system password prompt") { alert in
            for label in ["Not Now", "Not now", "Never for This Website", "Cancel"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
    }

    func testForumRoundTrip() throws {
        app.launch()

        signIn()
        shoot("01-channel-list")

        openGeneral()
        shoot("02-channel-feed")

        let title = "Smoke thread \(Int(Date().timeIntervalSince1970))"
        composePost(title: title)
        shoot("04-after-post")

        openPost(titled: title)
        shoot("05-post-thread")

        react()
        comment("Replying to my own thread so the comment path is exercised end to end.")
        shoot("06-thread-with-comment")

        deleteOwnPost()
        shoot("07-after-delete")

        // Guideline 1.2's headline mechanism, on someone else's content —
        // reporting your own is refused server-side ("You can't report your own
        // content"), and the UI correspondingly hides the affordance there.
        reportSeededPost()
        shoot("09-after-report")
    }

    // MARK: - Steps

    /// Signs in, or adopts the session that is already there.
    ///
    /// Tokens live in the keychain, which survives both app termination and a
    /// reinstall on the simulator — so a second run of this test starts signed
    /// in. Asserting on the signed-out state would make the test pass exactly
    /// once, which is the least useful kind of test.
    private func signIn() {
        let cta = app.buttons["home.signInCTA"]

        // Presence of the **Channels tab** is not a session check: the tab is
        // gated on `FWBFeatures.channels` alone and is drawn signed out too,
        // where it shows a "Members only" prompt. The sign-in CTA on Home is the
        // actual signal, and keying on the tab sent an earlier run straight into
        // the signed-out Channels tab looking for a channel list.
        guard cta.waitForExistence(timeout: 12) else {
            openChannelsTab()
            return
        }
        cta.tap()

        let continueWithEmail = app.buttons["auth.continueWithEmail"]
        XCTAssertTrue(continueWithEmail.waitForExistence(timeout: timeout), "welcome screen should appear")
        continueWithEmail.tap()

        let emailField = app.textFields.element(boundBy: 0)
        XCTAssertTrue(emailField.waitForExistence(timeout: timeout), "sign-in form should appear")
        type(Self.email, into: emailField)
        type(Self.password, into: app.secureTextFields.element(boundBy: 0))
        app.buttons["signIn.submit"].tap()

        // The member was seeded through the API, so onboarding (terms + age) has
        // not been completed on this device and gates the session.
        clearOnboardingIfPresent()

        openChannelsTab()
    }

    /// Switches to the Channels tab and waits for it to actually be showing.
    ///
    /// iOS 26's floating tab bar does not always answer to `app.tabBars`, so this
    /// falls back to a plain button query, and — more importantly — **verifies
    /// the switch happened** rather than assuming the tap landed. An earlier run
    /// tapped something that resolved but never changed tabs, and the failure
    /// surfaced much later as "no channel listed", which pointed at the wrong
    /// thing entirely.
    private func openChannelsTab() {
        let navTitle = app.navigationBars["Channels"]

        for _ in 0..<3 {
            let candidates = [app.tabBars.buttons["Channels"], app.buttons["Channels"]]
            for candidate in candidates where candidate.exists {
                candidate.tap()
                if navTitle.waitForExistence(timeout: 6) { return }
            }
        }

        XCTFail("could not reach the Channels tab. Tree:\n\(app.debugDescription)")
    }

    /// The seeded member accepted nothing on this device, so the terms gate and
    /// the 18+ gate both stand between sign-in and the app.
    ///
    /// The accept toggle exists before it is reachable — it sits below the fold
    /// behind three legal links, so `exists` is true while `isHittable` is false
    /// and a straight `tap()` fails. Scrolling first is the fix, and it is also
    /// the honest interaction: the gate is designed to make you pass the links on
    /// the way to the switch.
    private func clearOnboardingIfPresent() {
        let accept = app.switches["onboarding.acceptToggle"]
        if accept.waitForExistence(timeout: 10) {
            var attempts = 0
            while !accept.isHittable && attempts < 6 {
                app.swipeUp()
                attempts += 1
            }
            // A SwiftUI `Toggle` with a long label reports a frame spanning the
            // whole row, so `tap()` aims at the centre — which is the middle of
            // the sentence, not the switch, and XCTest rejects it as not
            // hittable. Aiming at the trailing edge hits the control itself.
            accept.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()

            let cont = app.buttons["onboarding.continue"]
            if cont.waitForExistence(timeout: 5) {
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

    private func openGeneral() {
        let general = app.buttons["channel.general"].firstMatch
        let cell = app.cells.containing(.staticText, identifier: "general").firstMatch
        if general.waitForExistence(timeout: timeout) {
            general.tap()
        } else {
            XCTAssertTrue(cell.waitForExistence(timeout: timeout), "the general channel should be listed")
            cell.tap()
        }
        XCTAssertTrue(app.staticTexts["Welcome to the channels"].waitForExistence(timeout: timeout),
                      "the seeded pinned post should be visible in the feed")
    }

    private func composePost(title: String) {
        let newPost = app.buttons["channel.newPost"]
        XCTAssertTrue(newPost.waitForExistence(timeout: timeout),
                      "a poster-role member should be offered the compose button")
        newPost.tap()

        let titleField = app.textFields["composer.title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: timeout), "composer should appear")
        type(title, into: titleField)
        shoot("03-composer")
        type("Posted by the Phase 4 smoke test. Text-first: there is deliberately no media picker in this composer.",
             into: app.textViews["composer.body"].exists
                 ? app.textViews["composer.body"]
                 : app.textFields["composer.body"])

        let submit = app.buttons["composer.submit"]
        XCTAssertTrue(submit.isEnabled, "Post should enable once title and body are filled")
        submit.tap()

        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: timeout),
                      "the new post should appear in the feed")
    }

    private func openPost(titled title: String) {
        app.staticTexts[title].tap()
        XCTAssertTrue(app.buttons["thread.menu"].waitForExistence(timeout: timeout),
                      "post detail should appear")
    }

    private func react() {
        let reaction = app.buttons["reaction.toggle"].firstMatch
        XCTAssertTrue(reaction.waitForExistence(timeout: timeout), "the post should offer a reaction control")
        reaction.tap()
    }

    private func comment(_ text: String) {
        let field = app.textViews["thread.commentField"].exists
            ? app.textViews["thread.commentField"]
            : app.textFields["thread.commentField"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "a commenter should get a composer")
        type(text, into: field)
        app.buttons["thread.send"].tap()
        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: timeout),
                      "the comment should appear in the thread")
    }

    private func deleteOwnPost() {
        app.buttons["thread.menu"].tap()
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: timeout), "the author should be offered Delete")
        delete.tap()
        // Confirmation dialog.
        let confirm = app.buttons["Delete"].firstMatch
        if confirm.waitForExistence(timeout: 5) { confirm.tap() }
    }

    /// Opens the admin's seeded pinned post and reports it.
    private func reportSeededPost() {
        let seeded = app.staticTexts["Welcome to the channels"]
        XCTAssertTrue(seeded.waitForExistence(timeout: timeout),
                      "back on the feed, the seeded post should be there")
        seeded.tap()

        let menu = app.buttons["thread.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: timeout), "post detail should appear")
        menu.tap()

        let report = app.buttons["Report"].firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: timeout),
                      "another member's post must offer Report")
        report.tap()

        let reason = app.buttons["Spam"].firstMatch
        XCTAssertTrue(reason.waitForExistence(timeout: timeout), "the reason picker should appear")
        reason.tap()
        shoot("08-report-sheet")

        let submit = app.buttons["Submit"].firstMatch
        XCTAssertTrue(submit.isEnabled, "Submit should enable once a reason is chosen")
        submit.tap()

        XCTAssertTrue(menu.waitForExistence(timeout: timeout),
                      "the sheet should dismiss back to the thread")
    }

    // MARK: - Helpers

    private func type(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "field should exist before typing")
        field.tap()
        field.typeText(text)
    }

    /// Attaches the screenshot **and** writes it into the runner's Documents
    /// directory.
    ///
    /// The attachment alone is not enough: with no explicit test plan, a passing
    /// run discards `.keepAlways` attachments and the `.xcresult` comes back with
    /// an empty manifest (observed, not assumed). The simulator's filesystem is
    /// visible from the host, so a plain file write is the reliable channel —
    /// `xcrun simctl get_app_container <udid> <runner-id> data` resolves the
    /// path.
    private func shoot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent("shot-\(name).png")
        do {
            try screenshot.pngRepresentation.write(to: url)
            print("[smoke] wrote \(url.path)")
        } catch {
            XCTFail("could not write screenshot \(name): \(error)")
        }
    }
}
