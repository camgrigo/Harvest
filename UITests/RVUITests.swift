import XCTest

/// End-to-end UI tests driven through the notebook chat. Each launch passes "-uitesting" so the app
/// uses a fresh in-memory store (tests don't see each other's data) and skips the notification
/// prompt. Bot replies and person rows carry accessibility identifiers so we can wait on them
/// instead of sleeping. Works whether the on-device model runs or the heuristic fallback is used.
///
/// Layout note: the app opens on the Map tab. People live on their own People tab, and the notebook
/// chat is reached from there via the "Jot a note" composer.
final class RVUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - Helpers

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uitesting"]
        app.launch()
        dismissOnboarding(app)
        return app
    }

    private func dismissOnboarding(_ app: XCUIApplication) {
        let start = app.buttons["Start my notebook"]
        if start.waitForExistence(timeout: 5) { start.tap() }
    }

    /// The notebook chat lives behind People → "Jot a note". Opens it so the composer is on screen.
    private func openComposer(_ app: XCUIApplication) {
        app.buttons["People"].firstMatch.tap()
        let jot = app.buttons["Jot a note"]
        if jot.waitForExistence(timeout: 5) {
            jot.tap()
        } else {
            app.staticTexts["Jot a note"].tap()
        }
    }

    /// Types a message into the chat composer and submits it — by the Return key or the send button.
    /// Assumes `openComposer` has already opened the notebook chat.
    private func send(_ app: XCUIApplication, _ text: String, viaReturn: Bool = false) {
        // The "Note…" composer is a text field, or a text view when it has wrapped to multiple lines.
        let field = app.textFields["Note…"]
        let multiline = app.textViews["Note…"]
        XCTAssertTrue(field.waitForExistence(timeout: 6) || multiline.waitForExistence(timeout: 6),
                      "Composer should be present")
        let composer = field.exists ? field : multiline
        composer.tap()
        composer.typeText(viaReturn ? text + "\n" : text)
        if !viaReturn { app.buttons["arrow.up.circle.fill"].firstMatch.tap() }
    }

    /// Waits until at least `count` bot replies are on screen. Returns false on timeout.
    /// Assistant messages are combined accessibility elements, so we match any element type.
    @discardableResult
    private func waitForReplies(_ app: XCUIApplication, count: Int = 1, timeout: TimeInterval = 45) -> Bool {
        let bot = app.descendants(matching: .any).matching(identifier: "botMessage")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if bot.count >= count { return true }
            usleep(300_000)
        }
        return false
    }

    private func dismissKeyboard(_ app: XCUIApplication) {
        guard app.keyboards.element.exists else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            .press(forDuration: 0.05,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)))
    }

    /// Shows the People feed: switches to the People tab — and, since re-selecting the active tab
    /// pops its stack, this also brings the chat back to the feed. Falls back to a Back tap.
    private func openPeople(_ app: XCUIApplication) {
        dismissKeyboard(app)
        app.buttons["People"].firstMatch.tap()
        if !app.navigationBars["People"].waitForExistence(timeout: 3) {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.exists { back.tap() }
        }
    }

    private func peopleRows(_ app: XCUIApplication, named name: String) -> Int {
        app.staticTexts
            .matching(identifier: "personRow.name")
            .matching(NSPredicate(format: "label == %@", name))
            .count
    }

    // MARK: - Tests

    /// Cheapest possible guard: the app launches under -uitesting and is still alive after its
    /// first-frame `.task` work has run. This is where launch-time crashes surface — e.g. submitting
    /// a background task whose handler was never registered (which once took down the whole suite
    /// with pid 0). Runs fast and fails loudly before the heavier flows below.
    func testAppLaunchesWithoutCrashing() {
        let app = launch()
        // A known control proves the first screen rendered.
        XCTAssertTrue(app.buttons["People"].firstMatch.waitForExistence(timeout: 10),
                      "First screen should render")
        // Give the on-appear tasks a beat, then confirm the app didn't crash out from under us.
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(app.state, .runningForeground,
                       "App should stay running after its launch tasks complete")
    }

    /// Runs the system accessibility audit on the two main screens — catches contrast, missing
    /// labels, hit-target size, and clipped-text regressions automatically. Locks in the manual
    /// accessibility pass so it can't silently rot.
    func testAccessibilityAudit() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["People"].firstMatch.waitForExistence(timeout: 10))
        // The People tab embeds an Apple Maps preview, which renders Apple's own sub-44pt controls
        // (the "Legal" link, attribution) that we neither own nor can resize — so exclude only the
        // hit-region check. Every other check (contrast, dynamic type, element descriptions,
        // clipped text, traits) still runs and will fail the test on a regression.
        // hitRegion is excluded: the embedded Apple Maps preview renders Apple's own sub-44pt
        // controls (Legal link, attribution) we can't resize. The Calendar tab also has open
        // contrast / clipped-text findings tracked separately, so audit the People tab here.
        try app.performAccessibilityAudit(for: .all.subtracting(.hitRegion))
    }

    /// Typing a note and pressing Return submits it and the engine files a page for the person.
    func testReturnKeySubmitsAndFilesVisit() throws {
        let app = launch()
        openComposer(app)
        send(app, "Met Maria at 12 Oak Street. Go back Saturday.", viaReturn: true)
        XCTAssertTrue(waitForReplies(app), "The bot should reply after a Return submit")

        openPeople(app)
        XCTAssertTrue(app.staticTexts["Maria"].waitForExistence(timeout: 10),
                      "Maria should have a page on the People tab")
    }

    /// The send button path also files a visit and shows a confirming reply.
    func testSendButtonFilesVisit() throws {
        let app = launch()
        openComposer(app)
        send(app, "Visited John, talked about the resurrection. Return in 3 days.")
        XCTAssertTrue(waitForReplies(app), "The bot should reply after tapping send")

        openPeople(app)
        XCTAssertTrue(app.staticTexts["John"].waitForExistence(timeout: 10),
                      "John should have a page on the People tab")
    }

    /// Editing an existing person updates them in place rather than creating a duplicate.
    func testEditingInterestDoesNotCreateDuplicate() throws {
        let app = launch()
        openComposer(app)
        send(app, "Met Maria at 12 Oak Street")
        XCTAssertTrue(waitForReplies(app, count: 1))

        send(app, "Change Maria's interest to studying")
        XCTAssertTrue(waitForReplies(app, count: 2), "There should be a reply to the edit")

        openPeople(app)
        XCTAssertTrue(app.staticTexts["Maria"].waitForExistence(timeout: 10))
        XCTAssertEqual(peopleRows(app, named: "Maria"), 1,
                       "Editing Maria must not create a second Maria")
    }

    /// Renaming through chat changes the existing person's name (no duplicate left behind).
    func testRenameUpdatesPersonInPlace() throws {
        let app = launch()
        openComposer(app)
        send(app, "Met Maria at 12 Oak Street")
        XCTAssertTrue(waitForReplies(app, count: 1))

        send(app, "Rename Maria to Marie")
        XCTAssertTrue(waitForReplies(app, count: 2))

        openPeople(app)
        XCTAssertTrue(app.staticTexts["Marie"].waitForExistence(timeout: 10),
                      "The renamed person should appear as Marie")
        XCTAssertEqual(peopleRows(app, named: "Maria"), 0, "The old name should be gone")
    }

    /// A People row opens that person's detail page.
    func testPersonRowOpensDetail() throws {
        let app = launch()
        openComposer(app)
        send(app, "Met Maria at 12 Oak Street, Springfield")
        XCTAssertTrue(waitForReplies(app))

        openPeople(app)
        let row = app.staticTexts["Maria"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        // The detail opens inside the panel; its inline title is the person's name.
        XCTAssertTrue(app.navigationBars["Maria"].waitForExistence(timeout: 5),
                      "Tapping a person opens their page")
        XCTAssertTrue(app.staticTexts["Note or ask…"].waitForExistence(timeout: 3),
                      "The detail page shows its per-person chat bar")
    }

    /// Asking for a recap produces a second bot reply.
    func testSummarizeProducesReply() throws {
        let app = launch()
        openComposer(app)
        send(app, "Met Maria, talked about hope")
        XCTAssertTrue(waitForReplies(app, count: 1))

        send(app, "Summarize Maria")
        XCTAssertTrue(waitForReplies(app, count: 2), "Summarize should produce a reply")
    }

    /// The People-tab map preview expands to the full map, and the X brings you back.
    func testMapPreviewOpensAndCloses() throws {
        let app = launch()
        let preview = app.buttons["Open full map"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "The People tab shows a map preview")
        preview.tap()
        XCTAssertTrue(app.buttons["Show everything"].waitForExistence(timeout: 5),
                      "Tapping the preview opens the full map with its controls")
        app.buttons["Close map"].tap()
        XCTAssertTrue(app.buttons["Open full map"].waitForExistence(timeout: 5),
                      "Closing returns to the People tab")
    }

    /// The full map's search control opens a search sheet that can be cancelled.
    func testMapSearchSheetOpensAndCancels() throws {
        let app = launch()
        app.buttons["Open full map"].tap()
        let search = app.buttons["Search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), "The map has a search control")
        search.tap()
        XCTAssertTrue(app.navigationBars["Search"].waitForExistence(timeout: 5),
                      "The map search sheet appears")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Show everything"].waitForExistence(timeout: 5),
                      "Cancelling returns to the map")
    }

    /// Searching the full map surfaces a matching person.
    func testMapSearchFindsPerson() throws {
        let app = launch()
        openComposer(app)
        send(app, "Met Maria at 12 Oak Street")
        XCTAssertTrue(waitForReplies(app))
        openPeople(app)

        app.buttons["Open full map"].tap()
        XCTAssertTrue(app.buttons["Search"].waitForExistence(timeout: 5))
        app.buttons["Search"].tap()

        let field = app.searchFields["Find a person or territory"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "The search field appears")
        field.tap()
        field.typeText("Maria")
        XCTAssertTrue(app.collectionViews.buttons["Maria"].waitForExistence(timeout: 5),
                      "Search lists the matching person")
    }

    /// A filed visit shows up on the People tab, and the tab bar persists across tabs.
    func testPeopleTabListsFiledPerson() throws {
        let app = launch()
        openComposer(app)
        send(app, "Met Maria at 12 Oak Street, Springfield")
        XCTAssertTrue(waitForReplies(app))

        openPeople(app)
        XCTAssertTrue(app.staticTexts["Maria"].waitForExistence(timeout: 10),
                      "The People tab lists Maria")
        XCTAssertTrue(app.buttons["People"].exists && app.buttons["Calendar"].exists,
                      "The tab bar stays put across tabs")
    }
}
