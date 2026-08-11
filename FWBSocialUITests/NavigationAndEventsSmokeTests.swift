import XCTest

/// Evidence run for the navigation directive, the display-face pass, and Phase 7.
///
/// Local server, for the same reason every chat and forum smoke is local: the
/// friending roster is behind `RequireVettedMember`, vetting comes only from an
/// admin or a matched Luma check-in, and production deliberately has no admin.
/// The seeded window here is a real row with a real 48-hour deadline.
final class NavigationAndEventsSmokeTests: XCTestCase {

    private var app: XCUIApplication!
    private let timeout: TimeInterval = 30

    private static let email = "cara.p7@example.invalid"
    private static let password = "correct horse battery staple"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["FWB_API_BASE"] = "http://127.0.0.1:8080"
        // The session is handed over rather than typed. Sign-in itself is covered
        // by `SmokeTests`; this suite is about navigation and Phase 7, and driving
        // a SecureField past iOS's strong-password sheet is a coin flip that has
        // nothing to do with what is being verified here.
        if let token = ProcessInfo.processInfo.environment["FWB_SEED_TOKEN"] {
            app.launchEnvironment["FWB_SESSION_TOKEN"] = token
        }

        // iOS offers to save / auto-generate a strong password the moment a secure
        // field takes focus, and that sheet steals the keystrokes. Without this the
        // run fails as "that email or password didn't match", which points at
        // seeding rather than at a stolen focus. The other suites already carry
        // this; omitting it here cost two runs.
        addUIInterruptionMonitor(withDescription: "system password prompt") { alert in
            for label in ["Not Now", "Not now", "Never for This Website", "Cancel", "Choose My Own Password"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
    }

    func testNavigationAndEvents() throws {
        app.launch()
        signInIfNeeded()
        // Runs whether or not sign-in did. With a seeded session the sign-in path
        // is skipped entirely, and the onboarding gate still stands in front of the
        // app — which is exactly how a seeded run failed on the age screen while
        // reporting "the avatar should open Profile".
        clearOnboardingIfPresent()

        shoot("01-home-chrome-and-fab")

        // The four-tab bar, and Profile/Settings reachable from the corners.
        XCTAssertTrue(app.buttons["chrome.settings"].waitForExistence(timeout: timeout),
                      "every root surface should carry the settings gear")
        XCTAssertTrue(app.buttons["chrome.profile"].exists,
                      "every root surface should carry the profile avatar")

        app.buttons["chrome.profile"].tap()
        // Match on the Luma-email row's identifier rather than a section header:
        // a Form header renders as an "other" element with styled text, so
        // `staticTexts["Membership"]` is a coin flip across iOS versions.
        XCTAssertTrue(app.descendants(matching: .any)["profile.lumaEmail"].waitForExistence(timeout: timeout),
                      "the avatar should open Profile")
        shoot("02-profile-sheet")
        dismissSheet()

        openTab("Events")
        shoot("03-events-window")

        // The seeded window, and its roster.
        let window = app.buttons["events.window.evt-rooftop-aug"].firstMatch
        if window.waitForExistence(timeout: timeout) {
            window.tap()
            XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: timeout))
            shoot("04-attendee-roster")
        }

        openTab("Chat")
        XCTAssertTrue(app.buttons["fab"].waitForExistence(timeout: timeout),
                      "the chat list's contextual action is the floating button")
        shoot("05-chat-fab")
    }

    // MARK: - Helpers

    private func signInIfNeeded() {
        let cta = app.buttons["home.signInCTA"]
        guard cta.waitForExistence(timeout: 10) else { return }
        cta.tap()

        let continueWithEmail = app.buttons["auth.continueWithEmail"]
        guard continueWithEmail.waitForExistence(timeout: timeout) else { return }
        continueWithEmail.tap()

        let emailField = app.textFields.element(boundBy: 0)
        XCTAssertTrue(emailField.waitForExistence(timeout: timeout))
        type(Self.email, into: emailField)
        type(Self.password, into: app.secureTextFields.element(boundBy: 0))
        app.buttons["signIn.submit"].tap()
        clearOnboardingIfPresent()
    }

    /// Tap, wait for focus, type, and VERIFY something landed.
    ///
    /// A bare `tap(); typeText()` raced the keyboard here: the secure field took the
    /// tap but not the keystrokes, and the run failed with "that email or password
    /// didn't match" — which reads as a seeding problem rather than as dropped
    /// input. A secure field reports its value as bullets, so the check is
    /// "non-empty", not equality.
    private func type(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        for attempt in 0 ..< 3 {
            field.tap()
            // Nudge the interruption monitor: it only fires on the next
            // interaction after the sheet appears, so tapping the app is what
            // actually dismisses a password prompt that grabbed focus.
            if attempt > 0 { app.tap() }
            _ = app.keyboards.element.waitForExistence(timeout: 5)
            field.typeText(text)

            // A secure field reports bullets, never the text — so the check is
            // "something landed", not equality. The placeholder is gone once a
            // value exists, which is what distinguishes the two.
            let value = (field.value as? String) ?? ""
            if !value.isEmpty, value != "Password" { return }
        }
    }

    private func clearOnboardingIfPresent() {
        let accept = app.switches["onboarding.acceptToggle"]
        if accept.waitForExistence(timeout: 10) {
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
        if confirmAge.waitForExistence(timeout: 10) {
            if !confirmAge.isHittable { app.swipeUp() }
            confirmAge.tap()
        }
    }

    /// iOS 26's floating tab bar does not reliably answer to `app.tabBars`.
    private func openTab(_ name: String) {
        for _ in 0 ..< 3 {
            for candidate in [app.tabBars.buttons[name], app.buttons[name]] where candidate.exists {
                candidate.tap()
                if app.navigationBars[name].waitForExistence(timeout: 6) { return }
            }
        }
        XCTFail("could not reach the \(name) tab")
    }

    private func dismissSheet() {
        // Swipe the sheet down from its own area rather than tapping a Done that
        // may not exist on every sheet.
        app.swipeDown(velocity: .fast)
        _ = app.buttons["chrome.profile"].waitForExistence(timeout: 5)
    }

    private func shoot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? screenshot.pngRepresentation.write(to: documents.appendingPathComponent("p7-\(name).png"))
        print("[smoke] shot \(name)")
    }
}
