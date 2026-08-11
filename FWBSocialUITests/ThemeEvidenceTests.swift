import XCTest

/// Capture suite for the app-theme exploration (owner request 2026-08-11).
///
/// Not an assertion suite either — it drives the real Settings pickers and
/// photographs the result, so the owner can compare Standard / Pine / Clubhouse
/// side by side without building three times.
///
/// It doubles as the proof for the *other* half of that work: every capture of
/// the Settings sheet is taken with the sheet ALREADY OPEN when the picker was
/// changed. If the appearance override were still the old root-level
/// `.preferredColorScheme`, the Dark → System frames would come out dark, and
/// the app-theme frames would come out on the system's grey.
///
/// Runs signed OUT — the Feed's signed-out state is a fully painted screen with
/// a card, two buttons, a nav title and a tab bar on it, which is everything a
/// background theme needs to be judged against, and it needs no server.
final class ThemeEvidenceTests: XCTestCase {

    private var app: XCUIApplication!
    private let timeout: TimeInterval = 30

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        // Deliberately unreachable: the Feed's "couldn't load" state settles fast
        // and identically every run, where a live feed would not.
        app.launchEnvironment["FWB_API_BASE"] = "http://127.0.0.1:1"
    }

    func testCaptureAllThemes() throws {
        app.launch()

        XCTAssertTrue(app.buttons["chrome.settings"].waitForExistence(timeout: timeout),
                      "the gear should be on the Feed. Tree:\n\(app.debugDescription)")

        // Standard and Clubhouse carry both appearances; Pine forces dark, so a
        // "light" frame of it would be the same picture twice.
        let plan: [(theme: String, appearances: [String])] = [
            ("Standard",  ["Light", "Dark"]),
            ("Pine",      ["Dark"]),
            ("Clubhouse", ["Light", "Dark"])
        ]

        for (theme, appearances) in plan {
            for appearance in appearances {
                openSettings()
                // Order matters for what this proves: the appearance is set
                // FIRST, then the theme, then the sheet is photographed without
                // being closed — so the frame is of a sheet that restyled itself
                // underneath the member's finger.
                choose(appearance, in: "settings.appearanceTheme")
                choose(theme, in: "settings.appTheme")
                settle(1.5)
                shoot("settings-\(theme.lowercased())-\(appearance.lowercased())")

                dismissSheet()
                settle(1.5)
                shoot("feed-\(theme.lowercased())-\(appearance.lowercased())")
            }
        }
    }

    // MARK: - Driving

    private func openSettings() {
        let gear = app.buttons["chrome.settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: timeout), "the gear should be on the Feed")
        gear.tap()
        XCTAssertTrue(app.buttons["sheet.done"].waitForExistence(timeout: timeout),
                      "the Settings sheet should open. Tree:\n\(app.debugDescription)")
    }

    private func dismissSheet() {
        let done = app.buttons["sheet.done"]
        if done.waitForExistence(timeout: 5) { done.tap() }
    }

    /// Taps a `Picker` row and then its option. A Form picker renders as a menu
    /// button, so the option is a separate element that only exists once the menu
    /// is up — hence the two waits rather than one chained query.
    private func choose(_ option: String, in identifier: String) {
        let picker = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: timeout),
                      "\(identifier) should be in Settings. Tree:\n\(app.debugDescription)")

        // Already on the wanted value: the menu button's value carries the
        // selection, and re-picking it would be a wasted menu round trip.
        if (picker.value as? String) == option { return }
        picker.tap()

        let choice = app.buttons[option].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 10),
                      "\(option) should be offered by \(identifier). Tree:\n\(app.debugDescription)")
        choice.tap()
    }

    // MARK: - Capture

    private func settle(_ seconds: TimeInterval) {
        _ = XCTWaiter.wait(for: [expectation(description: "settle")], timeout: seconds)
    }

    private func shoot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent("\(name).png")
        do {
            try screenshot.pngRepresentation.write(to: url)
            print("[shot] wrote \(url.path)")
        } catch {
            XCTFail("could not write \(name): \(error)")
        }
    }
}
