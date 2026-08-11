import XCTest

/// Evidence for the launch-prefetch directive (owner 2026-08-11): **a member
/// never sees a tab load.**
///
/// The claim being tested is a negative one — no spinner, no empty state, no
/// flash — so the assertions are about what is absent at the moment the tab
/// appears, not about what eventually arrives. `waitForExistence` would hide
/// exactly the defect this is here to catch, so content is checked with `exists`
/// immediately after the tap and the elapsed time is recorded per tab.
///
/// Local server, seeded, for the same reason every other smoke here is local:
/// the channels list and the friending roster are behind `RequireVettedMember`,
/// vetting comes only from an admin or a matched Luma check-in, and production
/// deliberately has no admin. The session is handed over through the DEBUG-only
/// `FWB_SESSION_TOKEN` seam rather than typed.
final class PrefetchEvidenceTests: XCTestCase {

    private var app: XCUIApplication!
    private let timeout: TimeInterval = 30

    /// Written next to the screenshots so the run is readable without opening
    /// the result bundle.
    private var notes: [String] = []

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchEnvironment["FWB_API_BASE"] = "http://127.0.0.1:8080"
        if let token = ProcessInfo.processInfo.environment["FWB_SEED_TOKEN"] {
            app.launchEnvironment["FWB_SESSION_TOKEN"] = token
        }
        if let refresh = ProcessInfo.processInfo.environment["FWB_SEED_REFRESH"] {
            app.launchEnvironment["FWB_REFRESH_TOKEN"] = refresh
        }
    }

    /// Swap the seeded session for the next launch. Used by the account-switch
    /// regression, which needs two different members on one install.
    private func seed(token key: String) {
        app.launchEnvironment["FWB_SESSION_TOKEN"] =
            ProcessInfo.processInfo.environment[key] ?? ""
        app.launchEnvironment["FWB_REFRESH_TOKEN"] = ""
    }

    override func tearDown() {
        writeNotes()
        super.tearDown()
    }

    // MARK: - Cold launch → tap each tab immediately

    func testEveryTabHasContentOnFirstTap() throws {
        let launchedAt = Date()
        app.launch()

        // The only wait in the test: the shell itself has to exist before a tab
        // can be tapped. Everything after this is measured, not waited on.
        XCTAssertTrue(app.buttons["chrome.settings"].waitForExistence(timeout: timeout),
                      "the tab shell should come up")
        note("shell up \(ms(since: launchedAt)) after launch")

        // Home is the launch tab, so it is checked where it already is.
        check(tab: "Feed",
              alreadyOpen: true,
              content: app.descendants(matching: .any)["home.feed"],
              contentDescription: "the announcements feed",
              screenshot: "01-feed-first-tap")

        check(tab: "Channels",
              content: app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "channel.")).firstMatch,
              contentDescription: "a channel row",
              screenshot: "02-channels-first-tap")

        check(tab: "Chat",
              content: app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "chat.conversation.")).firstMatch,
              contentDescription: "a conversation row",
              screenshot: "03-chat-first-tap")

        check(tab: "Events",
              content: app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "events.window.")).firstMatch,
              contentDescription: "an open friending window",
              screenshot: "04-events-first-tap")
    }

    // MARK: - Navigating away and back never reloads visibly

    func testReturningToATabDoesNotReload() throws {
        app.launch()
        XCTAssertTrue(app.buttons["chrome.settings"].waitForExistence(timeout: timeout))

        // Prime every tab once.
        for tab in ["Channels", "Events", "Feed"] { openTab(tab) }

        // Then come back to each and assert the content is there in the same
        // frame — no spinner, no empty state, nothing refetched on screen.
        for (tab, description) in [("Channels", "channel."), ("Events", "events.window.")] {
            openTab(tab)
            let content = app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH %@", description)).firstMatch
            XCTAssertTrue(content.exists, "\(tab) should still hold its content on return")
            XCTAssertEqual(app.activityIndicators.count, 0,
                           "\(tab) should not show a spinner on return")
            XCTAssertFalse(app.descendants(matching: .any)["empty.state"].exists,
                           "\(tab) should not flash an empty state on return")
            note("return to \(tab): content present, no spinner, no empty state")
        }

        // And a push/pop inside a tab — the deepest a member goes before coming
        // back to a list that used to refetch itself.
        openTab("Channels")
        let firstChannel = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "channel.")).firstMatch
        if firstChannel.exists {
            firstChannel.tap()
            _ = app.navigationBars.firstMatch.waitForExistence(timeout: timeout)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(firstChannel.waitForExistence(timeout: 5))
            XCTAssertEqual(app.activityIndicators.count, 0,
                           "popping back to the channel list should not reload it")
            note("pop back to Channels: no spinner")
        }
        shoot("05-channels-after-pop")
    }

    // MARK: - Sign-out clears every store

    func testSignOutClearsTheStores() throws {
        app.launch()
        XCTAssertTrue(app.buttons["chrome.profile"].waitForExistence(timeout: timeout))

        openTab("Channels")
        XCTAssertTrue(app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "channel.")).firstMatch
            .waitForExistence(timeout: timeout), "seeded member should have channels")

        openTab("Feed")
        signOutThroughProfile()

        // Home is not members-only: signing out leaves a working PUBLIC feed,
        // which is a different list from the one that was on screen. The helper
        // asserts the landing; this records it.
        shoot("06-signed-out-feed")

        // And the member-only tabs are back to their prompt with no member data
        // behind them.
        openTab("Channels")
        XCTAssertFalse(app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "channel.")).firstMatch.exists,
                       "channels must not survive sign-out")
        note("sign-out: public feed restored, channel rows cleared")
        shoot("07-signed-out-channels")
    }

    // MARK: - Owner bug 2026-08-11: the Feed was empty until you bounced the tab

    /// The reported symptom was an admin's own draft missing from a cold launch
    /// and staying missing through a pull-to-refresh, until the member left the
    /// tab and came back. The cause was the feed loading before session restore
    /// resolved: unauthenticated, it gets the PUBLIC route, which by definition
    /// cannot carry a draft.
    ///
    /// A draft is the sharpest possible probe for it — it exists on exactly one
    /// route, `/api/admin/announcements`, which cannot be reached without a
    /// session. If it is on screen at first look, the load happened after
    /// restore.
    func testAdminDraftIsOnTheFeedAtColdLaunch() throws {
        seed(token: "FWB_SEED_ADMIN_TOKEN")
        app.launch()
        XCTAssertTrue(app.buttons["chrome.settings"].waitForExistence(timeout: timeout))

        let draft = app.staticTexts["DRAFT Prefetch regression marker"]
        XCTAssertTrue(draft.waitForExistence(timeout: timeout),
                      "the admin's draft should be on the feed at cold launch, with no tab bounce")
        XCTAssertFalse(app.descendants(matching: .any)["empty.state"].exists,
                       "the feed should not have flashed an empty state")
        note("cold launch as admin: draft present without leaving the tab")
        shoot("08-admin-draft-cold-launch")

        // And pull-to-refresh reflects the CURRENT session rather than replaying
        // a cached signed-out answer (the second half of the report).
        app.descendants(matching: .any)["home.feed"].firstMatch.swipeDown(velocity: .slow)
        XCTAssertTrue(draft.waitForExistence(timeout: timeout),
                      "pull-to-refresh must not fall back to the public feed")
        note("pull-to-refresh as admin: draft still present")
        shoot("09-admin-draft-after-refresh")
    }

    // MARK: - Bug 8CC9EC4F: one account served another's channel list

    /// `URLCache` keys on the URL and ignores `Authorization`, and fwb-server
    /// labels the channel list `Cache-Control: public, max-age=60` even though
    /// its whole payload is the CALLER's resolved roles. On one install that
    /// meant the admin's list — private channels included — was handed to the
    /// next member who signed in.
    ///
    /// The fixture is chosen so the leak cannot hide: `media-1786422549` is a
    /// private channel the admin can see and the member cannot.
    func testChannelListDoesNotSurviveAnAccountSwitch() throws {
        let privateChannel = app.descendants(matching: .any)["channel.media-1786422549"]

        seed(token: "FWB_SEED_ADMIN_TOKEN")
        app.launch()
        XCTAssertTrue(app.buttons["chrome.profile"].waitForExistence(timeout: timeout))
        openTab("Channels")
        XCTAssertTrue(privateChannel.waitForExistence(timeout: timeout),
                      "the admin should see the private channel — otherwise this test proves nothing")
        note("admin sees the private channel")
        shoot("10-admin-channels")

        openTab("Feed")
        signOutThroughProfile()
        app.terminate()

        seed(token: "FWB_SEED_TOKEN")
        app.launch()
        XCTAssertTrue(app.buttons["chrome.profile"].waitForExistence(timeout: timeout),
                      "the member's seeded session should restore")
        openTab("Channels")
        XCTAssertTrue(app.descendants(matching: .any)["channel.general"].waitForExistence(timeout: timeout),
                      "the member should get their own channel list")
        XCTAssertFalse(privateChannel.exists,
                       "8CC9EC4F: the admin's private channel must not appear for the member")
        note("after the account switch the member sees their own list, not the admin's")
        shoot("11-member-channels-after-switch")
    }

    // MARK: - Helpers

    /// Tap a tab and assert, in the same breath, that the member is looking at
    /// content rather than at the app fetching it.
    private func check(
        tab: String,
        alreadyOpen: Bool = false,
        content: XCUIElement,
        contentDescription: String,
        screenshot: String
    ) {
        let tappedAt = Date()
        if !alreadyOpen { openTab(tab) }

        // The negative assertions FIRST — they are the point, and every query
        // costs time that would let a late-arriving fetch cover the defect up.
        let spinners = app.activityIndicators.count
        let emptyState = app.descendants(matching: .any)["empty.state"].exists
        let errorState = app.descendants(matching: .any)["error.state"].exists
        let hasContent = content.exists

        XCTAssertEqual(spinners, 0, "\(tab): a member should never see it load")
        XCTAssertFalse(emptyState, "\(tab): no empty state should flash before content")
        XCTAssertFalse(errorState, "\(tab): nothing should have failed")
        XCTAssertTrue(hasContent, "\(tab): \(contentDescription) should already be on screen")

        note("\(tab): content present \(ms(since: tappedAt)) after tap — "
             + "spinners=\(spinners) emptyState=\(emptyState) errorState=\(errorState)")
        shoot(screenshot)
    }

    /// Sign out through the Profile sheet.
    ///
    /// The row lives near the bottom of a lazy `List`, so it does not exist in
    /// the hierarchy until it has been scrolled to — a bare `waitForExistence`
    /// on it waits for something that will never appear on its own.
    private func signOutThroughProfile() {
        app.buttons["chrome.profile"].tap()
        let signOut = app.buttons["profile.signOut"]
        for _ in 0 ..< 8 where !signOut.exists { app.swipeUp() }
        XCTAssertTrue(signOut.waitForExistence(timeout: timeout), "Profile should offer Sign out")
        if !signOut.isHittable { app.swipeUp() }
        signOut.tap()

        // The confirmation is an action sheet; matching inside it avoids the
        // row of the same name behind it.
        let confirm = app.sheets.buttons["Sign out"].firstMatch
        if confirm.waitForExistence(timeout: 10) {
            confirm.tap()
        } else {
            app.buttons.matching(identifier: "Sign out")
                .allElementsBoundByIndex.last?.tap()
        }
        XCTAssertTrue(app.buttons["home.signInCTA"].waitForExistence(timeout: timeout),
                      "signing out should land on the signed-out feed")
    }

    /// iOS 26's floating tab bar does not reliably answer to `app.tabBars`.
    private func openTab(_ name: String) {
        for _ in 0 ..< 3 {
            for candidate in [app.tabBars.buttons[name], app.buttons[name]] where candidate.exists {
                candidate.tap()
                if app.navigationBars[name == "Feed" ? "fwb social" : name]
                    .waitForExistence(timeout: 6) { return }
                return
            }
        }
        XCTFail("could not reach the \(name) tab")
    }

    private func ms(since start: Date) -> String {
        String(format: "%.0fms", Date().timeIntervalSince(start) * 1000)
    }

    private func note(_ line: String) {
        notes.append(line)
        print("[prefetch] \(line)")
    }

    private func shoot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? screenshot.pngRepresentation.write(to: documents.appendingPathComponent("prefetch-\(name).png"))
        print("[prefetch] shot \(name)")
    }

    private func writeNotes() {
        guard !notes.isEmpty else { return }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let text = notes.joined(separator: "\n") + "\n"
        try? text.write(to: documents.appendingPathComponent("prefetch-notes-\(name).txt"),
                        atomically: true, encoding: .utf8)
    }
}
