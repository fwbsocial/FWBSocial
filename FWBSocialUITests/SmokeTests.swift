import XCTest

/// End-to-end smoke against the **live** server.
///
/// This is the Phase 3 deliverable check: a real account is created, taken
/// through onboarding in the app, used to read the announcements feed, signed
/// out, signed back in, and finally deleted through the app's own
/// delete-account flow. It runs against `fwb-server.fly.dev` because that is
/// what the app ships against, and because a mocked version of this would prove
/// nothing about the contract.
///
/// **It creates a real account and deletes it again**, which is why it lives on
/// its own `FWBSocialSmoke` scheme, deliberately outside the default scheme's
/// test action. A routine `xcodebuild test` must not be able to leave junk in
/// production.
///
/// The address is always `@example.invalid` — a reserved TLD that can never
/// resolve — so a stray account can never receive mail or collide with a real
/// member's address. Email verification is dormant server-side, so an unverified
/// account is the expected state.
///
/// **One deliberate gap.** The account is created over HTTP rather than by
/// typing into the register form. That screen's password field is
/// `.textContentType(.newPassword)`, which is the right content type for a
/// signup field — it is what makes iOS offer a strong password and save the new
/// credential — but it also hands the field to the system's automatic
/// strong-password affordance, which swallows synthesised keystrokes entirely.
/// A `.password` field (the sign-in screen) accepts them fine; this was
/// confirmed by probing both. Rather than degrade a real product behaviour to
/// suit a test, the form is exercised up to that field and the session is then
/// established through the sign-in screen, which hits the same server with the
/// same credentials. Registration by hand still wants a human once per build.
final class SmokeTests: XCTestCase {

    private var app: XCUIApplication!
    private var account: TestAccount?

    private let timeout: TimeInterval = 30
    private static let password = "correct horse battery staple"
    private static let baseURL = "https://fwb-server.fly.dev"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()

        // iOS's "Save Password?" prompt is presented by a *separate process*, so
        // it never appears in `app`'s element tree — it simply swallows every
        // subsequent tap and swipe, which looks exactly like the app having hung.
        // An interruption monitor is the only mechanism that reliably catches an
        // out-of-process alert whose owner isn't known in advance.
        addUIInterruptionMonitor(withDescription: "system password prompt") { alert in
            for label in ["Not Now", "Not now", "Never for This Website", "Cancel"] {
                let button = alert.buttons[label]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }
    }

    override func tearDown() {
        // A failed run must not leave an account behind. `account` is cleared
        // once the app's own delete flow has done the job, so this only fires on
        // the failure path.
        if let account {
            print("[smoke] cleaning up leftover account \(account.email)")
            Self.deleteAccount(token: account.accessToken)
        }
        super.tearDown()
    }

    func testOnboardReadFeedSignOutAndDeleteAccount() throws {
        app.launch()

        // MARK: 1 — Signed-out home
        //
        // The Guideline 2.1 surface: the announcements feed has to render before
        // anyone signs in. Empty is a pass; failing to load is not.
        let signInCTA = app.buttons["home.signInCTA"]
        XCTAssertTrue(signInCTA.waitForExistence(timeout: timeout),
                      "signed-out Home should offer a sign-in CTA")
        XCTAssertTrue(app.staticTexts["fwb social"].exists, "brand text is lowercase 'fwb social'")
        attachScreenshot(named: "01-home-signed-out")

        // MARK: 2 — The auth screens
        signInCTA.tap()

        let createAccountLink = app.buttons["auth.createAccount"]
        XCTAssertTrue(createAccountLink.waitForExistence(timeout: timeout), "welcome screen should appear")
        attachScreenshot(named: "02-auth-welcome")

        // The register form, exercised as far as the automation can take it.
        createAccountLink.tap()
        let nameField = app.textFields["register.displayName"]
        XCTAssertTrue(nameField.waitForExistence(timeout: timeout), "register form should appear")
        let email = "phase3-smoke+\(UUID().uuidString.prefix(8).lowercased())@example.invalid"
        type("Phase 3 Smoke", into: nameField)
        type(email, into: app.textFields["register.email"])
        attachScreenshot(named: "03-register-form")
        XCTAssertFalse(app.buttons["register.submit"].isEnabled,
                       "Create account stays disabled until a password is entered")

        // MARK: 3 — Create the account on the live server, then sign in
        let created = try XCTUnwrap(Self.register(email: email, password: Self.password),
                                    "registration against \(Self.baseURL) should succeed")
        account = created

        app.navigationBars.buttons.element(boundBy: 0).tap()   // back to welcome
        app.buttons["auth.continueWithEmail"].tap()

        let signInEmail = app.textFields.element(boundBy: 0)
        XCTAssertTrue(signInEmail.waitForExistence(timeout: timeout), "sign-in form should appear")
        type(email, into: signInEmail)
        type(Self.password, into: app.secureTextFields.element(boundBy: 0))
        tap(app.buttons["signIn.submit"])
        dismissSavePasswordPrompt()

        // MARK: 4 — Onboarding: terms
        let acceptToggle = app.switches["onboarding.acceptToggle"]
        XCTAssertTrue(acceptToggle.waitForExistence(timeout: timeout),
                      "a member who has never accepted the terms should hit the gate on first sign-in")
        attachScreenshot(named: "04-onboarding-terms")

        // The toggle is the gate: Continue stays disabled until it flips, so the
        // switch's own value is what to wait on, not the tap returning.
        setOn(acceptToggle)

        let continueButton = app.buttons["onboarding.continue"]
        XCTAssertTrue(wait(for: continueButton, toBeEnabled: true),
                      "Continue should unlock once the terms are accepted")
        tap(continueButton)

        // MARK: 5 — Onboarding: the 18+ age gate
        //
        // In the Simulator the Declared Age Range API is unavailable, so this
        // exercises `AgeGatePolicy.allowWhenUnavailable`: the band is reported as
        // `unknown` and the member is let through. On a provisioned device this
        // presents the system sheet instead — which is exactly why the device leg
        // of this flow still needs a human.
        let confirmAge = app.buttons["onboarding.confirmAge"]
        XCTAssertTrue(confirmAge.waitForExistence(timeout: timeout), "age gate should follow the terms")
        attachScreenshot(named: "05-onboarding-age-gate")
        tap(confirmAge)

        // MARK: 6 — Signed-in home
        let feed = app.scrollViews["home.feed"]
        XCTAssertTrue(feed.waitForExistence(timeout: timeout),
                      "the gate should dismiss and reveal the announcements feed")
        // A brand-new account is `pending`, so the vetting card is what proves
        // this is the *signed-in* feed and not the signed-out one.
        XCTAssertTrue(app.staticTexts["Membership"].waitForExistence(timeout: timeout),
                      "a pending member should see the vetting-status card")
        XCTAssertFalse(app.buttons["home.signInCTA"].exists,
                       "the signed-out CTA should be gone once there's a session")
        attachScreenshot(named: "06-home-signed-in")

        // MARK: 7 — Profile
        app.tabBars.buttons["Profile"].tap()

        let deleteButton = app.buttons["profile.deleteAccount"]
        XCTAssertTrue(app.staticTexts[email].waitForExistence(timeout: timeout),
                      "Profile shows the signed-in address")
        attachScreenshot(named: "07-profile")
        // Deletion sits at the bottom of a lazy List, so the row does not exist
        // until it has been scrolled near.
        XCTAssertTrue(scrollUntilExists(deleteButton), "Profile should offer account deletion")
        XCTAssertTrue(scrollUntilExists(app.buttons["profile.signOut"]), "Profile should offer sign out")

        // MARK: 8 — Session restore on relaunch
        //
        // Two Phase 3 requirements in one step. The session has to survive a cold
        // launch from the Keychain, and the onboarding gate must NOT reappear for
        // a member who has already been through it — which is what proves that
        // state is server-backed rather than a per-launch prompt.
        //
        // Relaunching also avoids a second password entry, and with it iOS's
        // "Save Password?" prompt: that alert is owned by another process, so it
        // never shows up in the app's element tree and simply eats every
        // subsequent tap.
        app.terminate()
        app.launch()

        app.tabBars.buttons["Profile"].tap()
        XCTAssertTrue(app.staticTexts[email].waitForExistence(timeout: timeout),
                      "the session should be restored from the Keychain on relaunch")
        XCTAssertFalse(app.switches["onboarding.acceptToggle"].exists,
                       "the terms gate must not reappear for a member who already accepted")
        attachScreenshot(named: "08-session-restored")

        // MARK: 9 — Delete through the app's own flow, and leave nothing behind
        XCTAssertTrue(scrollUntilExists(deleteButton), "Profile should offer account deletion")
        tap(deleteButton)
        tapDialogButton("Delete account")

        XCTAssertTrue(app.buttons["Sign in"].waitForExistence(timeout: timeout),
                      "deleting signs the member out — the same path the Sign out button takes")
        attachScreenshot(named: "09-after-delete")

        // And it stays signed out across a relaunch, which is what proves the
        // Keychain was actually cleared rather than just the in-memory user.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["home.signInCTA"].waitForExistence(timeout: timeout),
                      "a deleted session must not come back on the next launch")
        attachScreenshot(named: "10-signed-out-after-relaunch")

        // The assertion that actually matters: the server agrees it is gone. A
        // deleted account's `/me` 404s, because the row is tombstoned and
        // `req.liveUser()` no longer finds it.
        XCTAssertEqual(Self.meStatus(token: created.accessToken), 404,
                       "the account should no longer exist on the server")
        account = nil
    }

    // MARK: - Live server helpers
    //
    // Hand-rolled rather than reaching into the app target. A UI test runs out of
    // process, and verifying the app's behaviour with the app's own networking
    // code would prove strictly less than this does.

    struct TestAccount {
        let email: String
        let accessToken: String
    }

    private static func register(email: String, password: String) -> TestAccount? {
        var request = URLRequest(url: URL(string: "\(baseURL)/api/auth/register")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("fwb-ios", forHTTPHeaderField: "X-App-Id")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "email": email,
            "password": password,
            "display_name": "Phase 3 Smoke",
        ])

        guard let data = send(request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String
        else { return nil }
        return TestAccount(email: email, accessToken: token)
    }

    private static func deleteAccount(token: String) {
        var request = URLRequest(url: URL(string: "\(baseURL)/api/auth/account")!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = send(request)
    }

    private static func meStatus(token: String) -> Int {
        var request = URLRequest(url: URL(string: "\(baseURL)/api/auth/me")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var status = -1
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? -1
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 30)
        return status
    }

    @discardableResult
    private static func send(_ request: URLRequest) -> Data? {
        var result: Data?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            result = data
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 30)
        return result
    }

    // MARK: - UI helpers

    /// Focus a field and type into it, verifying the text actually landed.
    ///
    /// Two things make the naive `tap()` + `field.typeText()` unreliable, and both
    /// fail *silently* — surfacing 30 seconds later as "the next screen never
    /// appeared", pointing at entirely the wrong place:
    ///
    ///  * A tap that misses leaves the field unfocused and the keystrokes go
    ///    nowhere. Hence the retry.
    ///  * An empty field reports its **placeholder** as its `value`, so
    ///    "value is non-empty" is not evidence that anything was typed.
    ///
    /// It deliberately does NOT wait for `app.keyboards`: the Simulator defaults
    /// to a connected hardware keyboard, so a field can be "Keyboard Focused"
    /// with no software keyboard on screen at all.
    private func type(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "field should exist before typing")

        for attempt in 1...3 {
            field.tap()
            app.typeText(text)
            if !contents(of: field).isEmpty { return }
            XCTAssertTrue(attempt < 3,
                          "typing into '\(field.identifier)' never took — the field is still empty")
        }
    }

    /// Tap an element, scrolling it into view first and falling back to a
    /// coordinate tap.
    ///
    /// `isHittable` is not the same question as "is it on screen". A SwiftUI
    /// `Toggle`'s accessibility element spans the whole row — label text and
    /// all — so its centre hit-tests to the `Text`, and XCUITest calls the switch
    /// un-hittable while it sits in plain view. A leftover keyboard, and a row
    /// tucked under the tab bar, produce the same symptom for different reasons.
    ///
    /// `aimX` is where the fallback lands, as a fraction of the element's width.
    /// It matters: the default centre is right for a button, but a `Toggle`'s
    /// control is at its trailing edge. Aiming at the trailing edge of a *row*
    /// near the bottom of the screen is how an earlier version of this helper
    /// managed to tap the Settings tab instead.
    private func tap(_ element: XCUIElement, aimX: CGFloat = 0.5) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "element should exist before tapping")

        if !element.isHittable, app.keyboards.element.exists {
            app.keyboards.buttons["Return"].firstMatch.tap()
        }
        if element.isHittable {
            element.tap()
            return
        }

        // Genuinely off-screen, or hiding under the tab bar? Scroll toward it.
        for _ in 0..<4 where !element.isHittable {
            app.swipeUp()
        }
        if element.isHittable {
            element.tap()
            return
        }

        element.coordinate(withNormalizedOffset: CGVector(dx: aimX, dy: 0.5)).tap()
    }

    /// Dismiss iOS's "Save Password?" prompt.
    ///
    /// It is a SpringBoard alert, not part of the app, so it does not appear in
    /// `app`'s element tree at all — it just silently swallows every subsequent
    /// tap and swipe, which looks exactly like the app having hung. Signing in
    /// with a password triggers it every time.
    private func dismissSavePasswordPrompt() {
        // Try the usual owners by name first — cheap, and avoids waiting on the
        // monitor when the alert is somewhere findable.
        for bundleId in ["com.apple.springboard", "com.apple.Passwords", "com.apple.AuthKitUI"] {
            let host = XCUIApplication(bundleIdentifier: bundleId)
            for label in ["Not Now", "Not now"] {
                let button = host.buttons[label]
                if button.waitForExistence(timeout: 2) {
                    button.tap()
                    return
                }
            }
        }
        // Otherwise nudge the app: an interruption monitor only evaluates when
        // the test next interacts with the application under test.
        app.swipeUp()
        _ = wait(until: { self.app.tabBars.firstMatch.isHittable }, timeout: 5)
    }

    /// Tap a button inside a confirmation dialog.
    ///
    /// Two things make this fiddly. The dialog's button carries the same *label*
    /// as the row that raised it ("Delete account"), so an unscoped label query
    /// matches two elements; and `matching(identifier:)` does not help, because
    /// the dialog's button has a label and no identifier while the row has the
    /// reverse. Scoping to the presented sheet or alert disambiguates; failing
    /// that, the last match wins, since the dialog is presented above the row.
    private func tapDialogButton(_ label: String) {
        // A fresh predicate per query: `NSPredicate` is not Sendable, and reusing
        // one across the `XCUIElementQuery` calls trips strict concurrency.
        func labelled(_ container: XCUIElementQuery) -> XCUIElementQuery {
            container.buttons.matching(NSPredicate(format: "label == %@", label))
        }

        for container in [app.sheets, app.alerts] {
            let button = labelled(container).firstMatch
            if button.waitForExistence(timeout: 5) {
                button.tap()
                return
            }
        }

        let matches = app.descendants(matching: .button)
            .matching(NSPredicate(format: "label == %@", label))
        guard matches.count > 0 else {
            attachScreenshot(named: "failure-no-dialog-\(label)")
            XCTFail("no button labelled '\(label)' — the confirmation dialog never opened")
            return
        }
        matches.element(boundBy: matches.count - 1).tap()
    }

    /// Scroll a lazy list until the element materialises.
    ///
    /// A SwiftUI `List` doesn't create rows that are far off screen, so
    /// `waitForExistence` on a bottom row waits for something that will never
    /// appear until it is scrolled toward.
    private func scrollUntilExists(_ element: XCUIElement, swipes: Int = 8) -> Bool {
        if element.waitForExistence(timeout: 3) { return true }
        for _ in 0..<swipes {
            app.swipeUp()
            if element.exists { return true }
        }
        return element.exists
    }

    /// Flip a switch on, retrying if the first tap didn't take.
    ///
    /// SwiftUI reports a `Toggle`'s state as `"0"` / `"1"`, and a tap that lands
    /// on the label rather than the control is a no-op — so the value, not the
    /// tap, is the signal that it worked.
    private func setOn(_ toggle: XCUIElement) {
        for attempt in 1...3 {
            if (toggle.value as? String) == "1" { return }
            tap(toggle, aimX: 0.92)
            _ = wait(until: { (toggle.value as? String) == "1" })
            XCTAssertTrue(attempt < 3 || (toggle.value as? String) == "1",
                          "'\(toggle.identifier)' never switched on")
        }
    }

    private func wait(for element: XCUIElement, toBeEnabled enabled: Bool) -> Bool {
        wait(until: { element.isEnabled == enabled })
    }

    /// Poll a condition. `XCTNSPredicateExpectation` would do, but this reads
    /// plainly and keeps the timeout in one place.
    private func wait(until condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(200_000)
        }
        return condition()
    }

    /// The field's actual contents, with the placeholder discounted. UIKit
    /// reports `value == placeholderValue` for an empty field, which makes every
    /// empty field look filled.
    private func contents(of field: XCUIElement) -> String {
        let value = field.value as? String ?? ""
        return value == (field.placeholderValue ?? "") ? "" : value
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
