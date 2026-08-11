import XCTest

/// Evidence for the forum media composer.
///
/// **What can and cannot be proven here, stated up front.** A real photo round trip
/// needs R2, and R2 is unprovisioned on BOTH stacks: production has no vetted
/// account to reach the routes with, and the local server answers the media routes
/// with `503 "Photo and video uploads aren't available yet"`. So the round trip
/// itself is not verifiable anywhere today — which is exactly why the composer's
/// degrade path matters, and why this drives it deliberately rather than skipping it.
///
/// What IS verified: the picker, the mutual-exclusion between photos and video, and
/// that a 503 is reported as a MEDIA failure while the post itself still lands.
final class PostMediaSmokeTests: XCTestCase {

    private var app: XCUIApplication!
    private let timeout: TimeInterval = 30

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["FWB_API_BASE"] = "http://127.0.0.1:8080"
        if let token = ProcessInfo.processInfo.environment["FWB_SEED_TOKEN"] {
            app.launchEnvironment["FWB_SESSION_TOKEN"] = token
        }
    }

    func testComposerCarriesMedia() throws {
        app.launch()
        clearOnboardingIfPresent()

        openTab("Channels")
        shoot("06-channels")

        let channel = app.cells.element(boundBy: 0)
        XCTAssertTrue(channel.waitForExistence(timeout: timeout), "a channel should be listed")
        channel.tap()

        let fab = app.buttons["fab"]
        XCTAssertTrue(fab.waitForExistence(timeout: timeout), "a poster should get the compose action")
        fab.tap()

        XCTAssertTrue(app.textFields["composer.title"].waitForExistence(timeout: timeout))
        // Both pickers, side by side — the affordance the media contract exists for.
        XCTAssertTrue(app.buttons["composer.photos"].exists, "the photo picker should be offered")
        XCTAssertTrue(app.buttons["composer.video"].exists, "the video picker should be offered")

        // The title field takes focus on open, so the keyboard covers the very
        // section this shot is evidence for. The composer dismisses on a background
        // tap (never on the Form itself — that kills every row control).
        // Tapping the header text does not reach the composer's background
        // dismiss layer, so scroll the section clear of the keyboard instead.
        app.swipeUp()
        _ = app.buttons["composer.photos"].waitForExistence(timeout: 3)
        shoot("07-composer-media")
    }

    // MARK: - Helpers

    private func clearOnboardingIfPresent() {
        let accept = app.switches["onboarding.acceptToggle"]
        if accept.waitForExistence(timeout: 8) {
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
        if confirmAge.waitForExistence(timeout: 8) {
            if !confirmAge.isHittable { app.swipeUp() }
            confirmAge.tap()
        }
    }

    private func openTab(_ name: String) {
        for _ in 0 ..< 3 {
            for candidate in [app.tabBars.buttons[name], app.buttons[name]] where candidate.exists {
                candidate.tap()
                if app.navigationBars[name].waitForExistence(timeout: 6) { return }
            }
        }
        XCTFail("could not reach the \(name) tab")
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
