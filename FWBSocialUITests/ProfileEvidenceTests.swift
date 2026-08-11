import XCTest

/// Evidence for the two owner features on Edit profile: **live username
/// availability** and **avatar upload**.
///
/// A *capture* suite, in the shape `ScreenshotCaptureTests` established — each
/// state is driven for real against a local seeded server and photographed, and
/// the screenshots are the deliverable alongside the assertions.
///
/// Local, and specifically NOT production: the availability route is
/// authenticated, changing a username writes to a real row, and an avatar upload
/// puts an object in a real bucket. The session is handed over through the
/// DEBUG-only `FWB_SESSION_TOKEN` seam rather than typed — iOS's strong-password
/// sheet steals focus from a `SecureField` and loses runs.
///
/// `FWB_API_BASE` points at **8081**, a second local instance with R2 pointed at
/// a loopback object store. The everyday local server has no R2 credentials, so
/// `POST /api/auth/avatar` answers 503 there by design.
final class ProfileEvidenceTests: XCTestCase {

    private var app: XCUIApplication!
    private let timeout: TimeInterval = 30
    private var notes: [String] = []

    /// A handle nobody holds, stable for the run so the assertions can name it.
    /// Typed with capitals on purpose: the server lowercases before storing, and
    /// the field has to preview that rather than echo what was typed.
    private static let freeHandleTyped = "RobinQA.Vale"
    private static let freeHandleCanonical = "robinqa.vale"

    /// The seeded member this suite must be signed in as. Asserted, not assumed —
    /// see `openEditProfile`.
    private static let expectedDisplayName =
        ProcessInfo.processInfo.environment["FWB_SEED_DISPLAY_NAME"] ?? "Robin Vale"

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchEnvironment["FWB_API_BASE"] =
            ProcessInfo.processInfo.environment["FWB_API_BASE"] ?? "http://127.0.0.1:8081"
        // `xcodebuild test` forwards a variable to the UI-test RUNNER only when it
        // is prefixed `TEST_RUNNER_`, and the prefix is stripped on the way in.
        // Without it the seed silently never arrives and the app runs on whatever
        // session the keychain still holds.
        let token = ProcessInfo.processInfo.environment["FWB_SEED_TOKEN"] ?? ""
        XCTAssertFalse(token.isEmpty,
                       "FWB_SEED_TOKEN is empty — pass it as TEST_RUNNER_FWB_SEED_TOKEN")
        app.launchEnvironment["FWB_SESSION_TOKEN"] = token
        app.launchEnvironment["FWB_REFRESH_TOKEN"] =
            ProcessInfo.processInfo.environment["FWB_SEED_REFRESH"] ?? ""
        addUIInterruptionMonitor(withDescription: "system prompt") { alert in
            for label in ["Allow Full Access", "Allow", "Select More Photos", "OK", "Not Now"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
    }

    override func tearDown() {
        writeNotes()
        super.tearDown()
    }

    // MARK: - 01 · Username, state by state

    func test01UsernameStates() throws {
        app.launch()
        openEditProfile(shot: "01-edit-profile")

        // Taken — `ada` is a seeded member. The status has to say so and Save has
        // to be dead, because the write would 409.
        let taken = setUsername("ada")
        note("typed 'ada' → \(taken)")
        XCTAssertFalse(app.buttons["editProfile.save"].isEnabled,
                       "Save must be disabled while the handle is taken")
        shoot("02-username-taken")

        // Invalid, three different rules, each answered with ITS OWN message
        // rather than one generic refusal.
        let periods = setUsername("..bad..")
        note("typed '..bad..' → \(periods)")
        XCTAssertFalse(app.buttons["editProfile.save"].isEnabled)
        shoot("03-username-bad-periods")

        let short = setUsername("ab")
        note("typed 'ab' → \(short)")
        XCTAssertFalse(app.buttons["editProfile.save"].isEnabled)
        shoot("04-username-too-short")

        let reserved = setUsername("admin")
        note("typed 'admin' → \(reserved)")
        XCTAssertFalse(app.buttons["editProfile.save"].isEnabled)
        shoot("05-username-reserved")

        // Free — and typed with capitals, so the echo proves the canonical form.
        let free = setUsername(Self.freeHandleTyped)
        note("typed '\(Self.freeHandleTyped)' → \(free)")
        XCTAssertTrue(free.contains(Self.freeHandleCanonical),
                      "the available state must preview the CANONICAL handle, got: \(free)")
        XCTAssertFalse(free.contains(Self.freeHandleTyped),
                       "the echo must not repeat the capitals back, got: \(free)")
        XCTAssertTrue(app.buttons["editProfile.save"].isEnabled,
                      "Save must be live once the handle is free")
        shoot("06-username-available-canonical")

        // Save it, and see it on the profile behind.
        app.buttons["editProfile.save"].tap()
        let handle = app.staticTexts["@\(Self.freeHandleCanonical)"]
        XCTAssertTrue(handle.waitForExistence(timeout: timeout),
                      "the profile should show the saved handle. Tree:\n\(app.debugDescription)")
        note("saved → profile shows @\(Self.freeHandleCanonical)")
        shoot("07-profile-after-save")

        // And back in the editor it is now the member's OWN handle: neither taken
        // nor a change.
        app.buttons["profile.editProfile"].tap()
        let settled = waitForStatus(after: { })
        note("reopened editor with the saved handle → status: \(settled.isEmpty ? "(none — unchanged)" : settled)")
        XCTAssertTrue(app.buttons["editProfile.save"].isEnabled,
                      "an unchanged handle must not block Save")
        shoot("08-username-unchanged")
    }

    // MARK: - 02 · Avatar

    func test02AvatarUpload() throws {
        app.launch()
        openEditProfile(shot: "09-edit-profile-before-photo")

        app.buttons["editProfile.photo"].tap()

        XCTAssertTrue(tapFirstPhoto(), "could not reach a photo in the picker")

        XCTAssertTrue(app.staticTexts["Photo updated"].waitForExistence(timeout: timeout),
                      "the upload should confirm. Tree:\n\(app.debugDescription)")
        note("photo uploaded and confirmed")
        shoot("11-avatar-in-editor")

        // Out of the editor: the profile header reads the same `AuthService.user`
        // the upload wrote, so the new photo has to be there without a reload.
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.buttons["profile.editProfile"].waitForExistence(timeout: timeout))
        shoot("12-profile-header-avatar")

        // And the toolbar avatar on the surface behind — the "everywhere" half of
        // the claim, drawn by a different `AvatarView` in a different tree.
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(app.buttons["chrome.profile"].waitForExistence(timeout: timeout),
                      "dismissing the profile sheet should reveal the chrome")
        shoot("13-chrome-avatar")
    }

    // MARK: - Helpers

    /// Tap the first photo in the system picker.
    ///
    /// `PhotosPicker` presents `PHPickerViewController`, which is **remote UI
    /// hosted by another process** — its grid is not in the app's element tree at
    /// all (the app's own hierarchy reports the screen underneath). So the query
    /// has to be aimed at the hosting process, and which one that is has moved
    /// between iOS releases: try each, and each of the three element types the
    /// grid has been built from.
    private func tapFirstPhoto() -> Bool {
        let hosts: [XCUIApplication] = [
            XCUIApplication(bundleIdentifier: "com.apple.PhotosUIService"),
            XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow"),
            app
        ]
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            for host in hosts {
                for query in [host.collectionViews.cells, host.cells, host.images] {
                    let element = query.element(boundBy: 0)
                    guard element.exists, element.isHittable else { continue }
                    shoot("10-photo-picker")
                    element.tap()
                    note("picked a photo by element query")
                    return true
                }
            }
            usleep(300_000)
        }

        // Nothing queryable: on this OS the picker's grid is served by a process
        // XCUITest cannot attach to by bundle id, so there is no element to find
        // — the app's own tree reports the screen underneath, and the two
        // documented Photos hosts don't resolve. A coordinate tap goes through
        // the window server and lands on whatever is actually drawn there, which
        // is the only remaining way to drive it.
        //
        // The offset is the first cell of the grid, and the fixture photo is the
        // most recent item in this simulator's library, so it is that cell. Sanity
        // -checked by `10-photo-picker`, which is taken immediately before the tap.
        shoot("10-photo-picker")
        let firstCell = app.coordinate(withNormalizedOffset: CGVector(dx: 0.165, dy: 0.431))
        firstCell.tap()
        note("picked a photo by coordinate (picker grid is not queryable on this OS)")
        return true
    }

    private func openEditProfile(shot name: String) {
        XCTAssertTrue(app.buttons["chrome.profile"].waitForExistence(timeout: timeout),
                      "the signed-in shell should show the profile avatar. Tree:\n\(app.debugDescription)")
        app.buttons["chrome.profile"].tap()
        XCTAssertTrue(app.buttons["profile.editProfile"].waitForExistence(timeout: timeout),
                      "Profile should offer Edit profile")

        // WHO is signed in, asserted before anything is written.
        //
        // The seam this suite uses writes the seeded token into the KEYCHAIN,
        // and the keychain outlives the process and the install. If the seed
        // never arrives — `xcodebuild` only forwards variables to a UI-test
        // runner when they are prefixed `TEST_RUNNER_` — the app happily runs on
        // whatever session a previous suite left behind, every assertion here
        // still passes, and a username rename lands on someone else's row. That
        // happened; this is the check that would have caught it in the first
        // second instead of in the database afterwards.
        XCTAssertTrue(app.staticTexts[Self.expectedDisplayName].waitForExistence(timeout: timeout),
                      "expected to be signed in as \(Self.expectedDisplayName) — the seeded session did not take. Tree:\n\(app.debugDescription)")
        app.buttons["profile.editProfile"].tap()
        XCTAssertTrue(app.textFields["editProfile.username"].waitForExistence(timeout: timeout),
                      "the editor should show a username field")
        shoot(name)
    }

    /// Replace the username field's contents and return the settled status text.
    @discardableResult
    private func setUsername(_ text: String) -> String {
        let field = app.textFields["editProfile.username"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.tap()
        let existing = (field.value as? String) ?? ""
        // An empty SwiftUI TextField reports its PLACEHOLDER as `value`, so
        // deleting blind would send a delete per placeholder character.
        if !existing.isEmpty, existing != "username" {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        let status = waitForStatus(after: { field.typeText(text) })
        // The status row sits directly under the field, which is exactly where
        // the keyboard is. Submit to dismiss it — otherwise every screenshot of
        // a username state is a screenshot of a keyboard.
        field.typeText("\n")
        return status
    }

    /// Run `action`, then wait out the 400 ms debounce and the round trip until
    /// the status row stops saying "Checking…".
    private func waitForStatus(after action: () -> Void) -> String {
        action()
        let status = app.descendants(matching: .any)["editProfile.usernameStatus"]
        let deadline = Date().addingTimeInterval(timeout)
        var label = ""
        while Date() < deadline {
            if status.exists {
                label = status.label
                if !label.isEmpty, !label.hasPrefix("Checking") { return label }
            } else {
                label = ""
            }
            usleep(200_000)
        }
        return label
    }

    private func note(_ line: String) {
        notes.append(line)
        print("[profile] \(line)")
    }

    private func shoot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? screenshot.pngRepresentation.write(to: documents.appendingPathComponent("profile-\(name).png"))
        print("[profile] shot \(name)")
    }

    private func writeNotes() {
        guard !notes.isEmpty else { return }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let text = notes.joined(separator: "\n") + "\n"
        try? (text as NSString).write(
            to: documents.appendingPathComponent("profile-notes-\(name).txt"),
            atomically: true, encoding: String.Encoding.utf8.rawValue)
    }
}
