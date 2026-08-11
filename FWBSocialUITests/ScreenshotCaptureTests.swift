import XCTest

/// App Store screenshot capture (ASC 6.9" size class).
///
/// Not an assertion suite — a *capture* suite. Every test drives the real app
/// against the local server, waits for the surface to be genuinely populated, and
/// writes a plain PNG into the runner's Documents directory so it can be pulled off
/// the simulator with `simctl get_app_container`. `.xcresult` attachments are
/// deliberately NOT the deliverable: they need unwrapping and they lose the exact
/// bytes.
///
/// **Each capture is its own test method** so the run order can be controlled from
/// the outside with `-only-testing:`. That matters for two reasons:
///
///  * `01-welcome` must run FIRST, before any test seeds a session, because the
///    seam writes the token into the keychain and the keychain outlives the process.
///  * The chat thread has to be built across TWO simulators in a fixed order —
///    Ada's device registers its key, then Mika's device registers and sends, then
///    Ada replies — because a device can only read messages sent after it enrolled.
///
/// Role is chosen by the `FWB_ROLE` environment variable (`ada` / `mika`), and the
/// session token is handed in through `FWB_SEED_TOKEN` rather than typed: iOS's
/// strong-password sheet steals focus from a `SecureField` and loses runs, which is
/// exactly why `APIClient`'s DEBUG seam exists.
final class ScreenshotCaptureTests: XCTestCase {

    private var app: XCUIApplication!
    private let timeout: TimeInterval = 40

    /// Ada — the account every screenshot is taken as.
    private static let adaUserId = "3602301A-9CAB-43B7-BC03-33F8F59E0059"

    private static let mikaMessages = [
        "Are you still up for the coffee crawl on Saturday?",
        "I can drive if you want — there's room for two more.",
        "Let's meet at the little place under the bridge at nine."
    ]

    private static let adaReplies = [
        "Yes! Nine works, I'll be there a few minutes early.",
        "A lift would be lovely. I'll bring the pastries."
    ]

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["FWB_API_BASE"] = "http://127.0.0.1:8080"
        // The welcome capture deliberately runs with no token so the app is
        // genuinely signed out.
        if let token = ProcessInfo.processInfo.environment["FWB_SEED_TOKEN"], !token.isEmpty {
            app.launchEnvironment["FWB_SESSION_TOKEN"] = token
        }
        if let refresh = ProcessInfo.processInfo.environment["FWB_SEED_REFRESH"], !refresh.isEmpty {
            app.launchEnvironment["FWB_REFRESH_TOKEN"] = refresh
        }
        addUIInterruptionMonitor(withDescription: "system prompt") { alert in
            for label in ["Not Now", "Not now", "Allow", "OK", "Cancel", "Choose My Own Password"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
    }

    // MARK: - 01 · Welcome (signed OUT)

    func test01Welcome() throws {
        app.launch()
        signOutIfSignedIn()

        let cta = app.buttons["home.signInCTA"]
        XCTAssertTrue(cta.waitForExistence(timeout: timeout),
                      "signed out, Home should offer the sign-in card. Tree:\n\(app.debugDescription)")
        cta.tap()

        // The wordmark, Sign in with Apple and Continue with email all have to be
        // on screen — a half-laid-out sheet is not a screenshot.
        XCTAssertTrue(app.buttons["auth.continueWithEmail"].waitForExistence(timeout: timeout),
                      "the welcome sheet should be up")
        XCTAssertTrue(app.staticTexts["fwb social"].waitForExistence(timeout: 10), "the wordmark should render")
        XCTAssertTrue(app.buttons["auth.createAccount"].exists)
        settle(2)
        shoot("01-welcome")
    }

    // MARK: - 02 · Home

    func test02Home() throws {
        app.launch()
        clearOnboardingIfPresent()

        // Wait for real content, not for the tab. An empty announcements feed is
        // the failure mode this whole suite exists to avoid.
        XCTAssertTrue(app.buttons["chrome.profile"].waitForExistence(timeout: timeout), "Home chrome should appear")
        waitForNoSpinner()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Alder House"))
                        .firstMatch.waitForExistence(timeout: timeout),
                      "a seeded announcement should be on the feed. Tree:\n\(app.debugDescription)")
        settle(2)
        shoot("02-home")
    }

    // MARK: - 03 · Channels (a post with its photo attachments)

    func test03Channels() throws {
        app.launch()
        clearOnboardingIfPresent()
        openTab("Channels")

        let general = app.buttons["channel.general"].firstMatch
        let generalCell = app.cells.containing(.staticText, identifier: "General").firstMatch
        if general.waitForExistence(timeout: timeout) {
            general.tap()
        } else if generalCell.waitForExistence(timeout: 10) {
            generalCell.tap()
        } else {
            XCTFail("the General channel should be listed. Tree:\n\(app.debugDescription)")
        }

        let coffee = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Coffee crawl")).firstMatch
        XCTAssertTrue(coffee.waitForExistence(timeout: timeout),
                      "the seeded Coffee crawl post should be in the General feed. Tree:\n\(app.debugDescription)")
        waitForNoSpinner()
        // Remote thumbnails have to finish decoding, or the grid captures as grey
        // placeholders — which reads as a broken feed in the store listing.
        settle(6)
        shoot("03-channels-feed")

        // Detail as well, so the better of the two can be chosen afterwards.
        coffee.tap()
        _ = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "walkable")).firstMatch
            .waitForExistence(timeout: timeout)
        waitForNoSpinner()
        settle(6)
        shoot("03-channels-detail")
    }

    // MARK: - 04a · Enrol this device's chat key

    /// Opening the Chat tab is what makes `ChatService.start()` publish this
    /// device's identity key. Nothing can be decrypted before it, on either side.
    func test04aEnrolChatDevice() throws {
        app.launch()
        clearOnboardingIfPresent()
        openTab("Chat")
        // Either state proves enrolment got far enough to render the list.
        let empty = app.staticTexts["No conversations yet"]
        let fab = app.buttons["fab"]
        XCTAssertTrue(fab.waitForExistence(timeout: timeout) || empty.waitForExistence(timeout: timeout),
                      "the chat list should render. Tree:\n\(app.debugDescription)")
        settle(8)
        shoot("04a-enrolled")
    }

    // MARK: - 04b · Mika starts the thread and sends (runs on the SECOND simulator)

    func test04bMikaSendsMessages() throws {
        app.launch()
        clearOnboardingIfPresent()
        openTab("Chat")
        // Give this device's own enrolment time to land before it wraps a key for
        // anyone: a message sealed before Ada's device is known is unreadable to her.
        settle(10)

        let existing = app.cells.element(boundBy: 0)
        if !existing.waitForExistence(timeout: 5) {
            let fab = app.buttons["fab"]
            XCTAssertTrue(fab.waitForExistence(timeout: timeout), "the compose action should be offered")
            fab.tap()

            let adaRow = app.buttons["chat.new.friend.\(Self.adaUserId)"].firstMatch
            XCTAssertTrue(adaRow.waitForExistence(timeout: timeout),
                          "Ada should be listed as a friend. Tree:\n\(app.debugDescription)")

            // Aim at the NAME, not the row's centre.
            //
            // The row is a `.buttonStyle(.plain)` Button whose label is an HStack
            // with a `Spacer()` in the middle and no `.contentShape(Rectangle())`,
            // so the centre of the row is a hit-testing hole. A centred `tap()`
            // lands in it, `selected` stays empty, Start stays disabled — and the
            // run then fails 40 seconds later on "the thread should open", which
            // reads as a chat bug rather than a missed tap. This is a real
            // app-side finding, not just a test detail.
            let start = app.buttons["chat.new.start"]
            for offset in [0.15, 0.30, 0.05] where !start.isEnabled {
                adaRow.coordinate(withNormalizedOffset: CGVector(dx: offset, dy: 0.5)).tap()
                _ = start.waitForExistence(timeout: 2)
                settle(1)
            }
            XCTAssertTrue(start.isEnabled,
                          "selecting a friend should enable Start. Tree:\n\(app.debugDescription)")
            start.tap()
        } else {
            existing.tap()
        }

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: timeout),
                      "the thread should open. Tree:\n\(app.debugDescription)")

        for message in Self.mikaMessages {
            send(message)
        }
        shoot("04b-mika-sent")
    }

    // MARK: - 04c · Ada replies, and the two-sided thread is captured

    func test04cChat() throws {
        app.launch()
        clearOnboardingIfPresent()
        openTab("Chat")

        let row = app.cells.element(boundBy: 0)
        XCTAssertTrue(row.waitForExistence(timeout: timeout),
                      "Mika's conversation should be listed. Tree:\n\(app.debugDescription)")
        row.tap()

        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: timeout), "the composer should appear")

        // Mika's side must have decrypted before replying, otherwise the capture is
        // a one-sided thread with a row of "can't be decrypted" placeholders.
        let firstIncoming = app.staticTexts[Self.mikaMessages[0]]
        XCTAssertTrue(firstIncoming.waitForExistence(timeout: timeout),
                      "Mika's messages should decrypt on this device. Tree:\n\(app.debugDescription)")

        for reply in Self.adaReplies where !app.staticTexts[reply].exists {
            send(reply)
        }

        // Dismiss the keyboard so the thread, not the keyboard, is the screenshot.
        dismissKeyboard()
        settle(3)
        shoot("04-chat")
    }

    // MARK: - 05 · Events — the open friending window's roster

    func test05Events() throws {
        app.launch()
        clearOnboardingIfPresent()
        openTab("Events")
        waitForNoSpinner()

        let window = app.buttons["events.window.evt-alder-house-mixer"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: timeout),
                      "the open window should be on the Events tab. Tree:\n\(app.debugDescription)")
        settle(2)
        shoot("05-events-window")

        window.tap()
        // The roster is the flagship surface: wait for a real attendee card.
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "events.add."))
                        .firstMatch.waitForExistence(timeout: timeout),
                      "attendee cards should render. Tree:\n\(app.debugDescription)")
        waitForNoSpinner()
        settle(4)
        shoot("05-events-roster")
    }

    // MARK: - 06 · Profile sheet

    func test06Profile() throws {
        app.launch()
        clearOnboardingIfPresent()

        let avatar = app.buttons["chrome.profile"]
        XCTAssertTrue(avatar.waitForExistence(timeout: timeout), "the corner avatar should be present")
        avatar.tap()

        XCTAssertTrue(app.descendants(matching: .any)["profile.lumaEmail"].waitForExistence(timeout: timeout),
                      "the avatar should open Profile. Tree:\n\(app.debugDescription)")
        // The friend code is one of the two things this shot is FOR, so wait for it
        // rather than for the sheet's mere existence.
        XCTAssertTrue(app.staticTexts["Friend code"].waitForExistence(timeout: 15),
                      "the friend code row should render")
        waitForNoSpinner()
        settle(3)
        shoot("06-profile")
    }

    // MARK: - Helpers

    private func send(_ text: String) {
        let composer = app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: timeout))
        composer.tap()
        _ = app.keyboards.element.waitForExistence(timeout: 5)
        composer.typeText(text)
        app.buttons["chat.send"].tap()
        // The bubble only renders because the app sealed the text, wrapped a key
        // per recipient device, POSTed it and decrypted the stored row back.
        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: timeout),
                      "the sent message should appear in the thread")
    }

    /// Answer SpringBoard's own alerts before photographing anything.
    ///
    /// `addUIInterruptionMonitor` is not enough here and the Home capture proved it:
    /// a monitor only fires on the NEXT interaction with the app, and a capture that
    /// waits for content and then shoots never interacts again — so the run passed
    /// with "fwb social Would Like to Send You Notifications" sitting across the
    /// middle of the feed. Query SpringBoard directly and dismiss.
    private func dismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0 ..< 3 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 3) else { return }
            // "Allow" rather than "Don't Allow": a denied prompt leaves the app in a
            // permission-refused state, and the point is a clean product shot.
            for label in ["Allow", "OK", "Not Now", "Don't Allow", "Continue"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); break }
            }
            settle(1)
        }
    }

    private func dismissKeyboard() {
        if app.keyboards.element.exists {
            // The app dismisses on a background tap; aim well clear of every row.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
            _ = app.keyboards.element.waitForExistence(timeout: 2)
        }
    }

    private func signOutIfSignedIn() {
        let avatar = app.buttons["chrome.profile"]
        guard avatar.waitForExistence(timeout: 12) else { return }
        // Signed out, Home still draws the chrome; the sign-in card is the tell.
        if app.buttons["home.signInCTA"].waitForExistence(timeout: 5) { return }

        avatar.tap()
        let signOut = app.buttons["profile.signOut"]
        var attempts = 0
        while !signOut.exists && attempts < 8 { app.swipeUp(); attempts += 1 }
        guard signOut.waitForExistence(timeout: 10) else { return }
        if !signOut.isHittable { app.swipeUp() }
        signOut.tap()
        // Confirmation dialog.
        let confirm = app.buttons["Sign out"].firstMatch
        if confirm.waitForExistence(timeout: 8) { confirm.tap() }
        _ = app.buttons["home.signInCTA"].waitForExistence(timeout: 20)
    }

    private func clearOnboardingIfPresent() {
        let accept = app.switches["onboarding.acceptToggle"]
        if accept.waitForExistence(timeout: 6) {
            var attempts = 0
            while !accept.isHittable && attempts < 6 { app.swipeUp(); attempts += 1 }
            let cont = app.buttons["onboarding.continue"]
            for _ in 0 ..< 4 where !cont.isEnabled {
                accept.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
                _ = cont.waitForExistence(timeout: 2)
            }
            if cont.exists, cont.isEnabled {
                if !cont.isHittable { app.swipeUp() }
                cont.tap()
            }
        }
        let confirmAge = app.buttons["onboarding.confirmAge"]
        if confirmAge.waitForExistence(timeout: 6) {
            if !confirmAge.isHittable { app.swipeUp() }
            confirmAge.tap()
        }
    }

    /// iOS 26's floating tab bar does not reliably answer to `app.tabBars`.
    private func openTab(_ name: String) {
        for _ in 0 ..< 4 {
            for candidate in [app.tabBars.buttons[name], app.buttons[name]] where candidate.exists {
                candidate.tap()
                if app.navigationBars[name].waitForExistence(timeout: 8) { return }
            }
        }
        XCTFail("could not reach the \(name) tab. Tree:\n\(app.debugDescription)")
    }

    /// A `ProgressView` in the capture is a failed capture, so wait one out rather
    /// than photographing it.
    private func waitForNoSpinner() {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if !app.activityIndicators.firstMatch.exists { return }
            settle(1)
        }
    }

    /// Let animations, image decodes and scroll-edge effects finish.
    private func settle(_ seconds: TimeInterval) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: seconds)
    }

    private func shoot(_ name: String) {
        // The APNs prompt arrives whenever registration returns, which is often
        // AFTER the surface has settled — so this belongs here, immediately before
        // the shutter, not once at launch.
        dismissSystemAlerts()
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent("\(name).png")
        do {
            try screenshot.pngRepresentation.write(to: url)
            print("[shot] wrote \(url.path) (\(screenshot.image.size) @\(screenshot.image.scale)x)")
        } catch {
            XCTFail("could not write \(name): \(error)")
        }
    }
}
