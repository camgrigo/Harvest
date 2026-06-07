import XCTest

/// End-to-end UI tests driven through the chat. Each launch passes "-uitesting" so the app uses
/// a fresh in-memory store (tests don't see each other's data) and skips the notification prompt.
/// Bot replies and person rows carry accessibility identifiers so we can wait on them instead of
/// sleeping. Works whether the on-device model runs or the heuristic fallback is used.
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

    private func composer(_ app: XCUIApplication) -> XCUIElement {
        app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.textViews.firstMatch
    }

    /// Types a message and submits it — by the Return key or the send button.
    private func send(_ app: XCUIApplication, _ text: String, viaReturn: Bool = false) {
        let field = composer(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Composer should be present")
        field.tap()
        field.typeText(viaReturn ? text + "\n" : text)
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

    /// People now live in the bottom sheet on the Map tab.
    private func openPeople(_ app: XCUIApplication) {
        dismissKeyboard(app)
        app.buttons["Map"].tap()
    }

    private func peopleRows(_ app: XCUIApplication, named name: String) -> Int {
        app.staticTexts
            .matching(identifier: "personRow.name")
            .matching(NSPredicate(format: "label == %@", name))
            .count
    }

    // MARK: - Tests

    /// Typing a note and pressing Return submits it and the engine files a page for the person.
    func testReturnKeySubmitsAndFilesVisit() throws {
        let app = launch()
        send(app, "Met Maria at 12 Oak Street. Go back Saturday.", viaReturn: true)
        XCTAssertTrue(waitForReplies(app), "The bot should reply after a Return submit")

        openPeople(app)
        XCTAssertTrue(app.staticTexts["Maria"].waitForExistence(timeout: 10),
                      "Maria should have a page on the People tab")
    }

    /// The send button path also files a visit and shows a confirming reply.
    func testSendButtonFilesVisit() throws {
        let app = launch()
        send(app, "Visited John, talked about the resurrection. Return in 3 days.")
        XCTAssertTrue(waitForReplies(app), "The bot should reply after tapping send")

        openPeople(app)
        XCTAssertTrue(app.staticTexts["John"].waitForExistence(timeout: 10),
                      "John should have a page on the People tab")
    }

    /// Editing an existing person updates them in place rather than creating a duplicate.
    func testEditingInterestDoesNotCreateDuplicate() throws {
        let app = launch()
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
        send(app, "Met Maria at 12 Oak Street, Springfield")
        XCTAssertTrue(waitForReplies(app))

        openPeople(app)
        let row = app.staticTexts["Maria"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        // The detail opens inside the panel; its inline title is the person's name.
        XCTAssertTrue(app.navigationBars["Maria"].waitForExistence(timeout: 5),
                      "Tapping a person opens their page")
        XCTAssertTrue(app.staticTexts["Chat about Maria"].exists,
                      "The detail page shows the per-person chat link")
    }

    /// Asking for a recap produces a second bot reply.
    func testSummarizeProducesReply() throws {
        let app = launch()
        send(app, "Met Maria, talked about hope")
        XCTAssertTrue(waitForReplies(app, count: 1))

        send(app, "Summarize Maria")
        XCTAssertTrue(waitForReplies(app, count: 2), "Summarize should produce a reply")
    }

    /// The Notebook and Map tabs have no navigation title bar (a deliberate design choice).
    func testNotebookAndMapHaveNoNavTitle() throws {
        let app = launch()
        XCTAssertFalse(app.navigationBars["Return Visits"].exists,
                       "The Notebook tab should not show a nav title")

        app.buttons["Map"].tap()
        XCTAssertFalse(app.navigationBars["Map"].exists,
                       "The Map tab should not show a nav title")
    }

    /// The combined Map tab opens with the people bottom sheet, and the tab bar stays put.
    func testMapTabShowsPeopleSheet() throws {
        let app = launch()
        send(app, "Met Maria at 12 Oak Street, Springfield")
        XCTAssertTrue(waitForReplies(app))

        dismissKeyboard(app)
        app.buttons["Map"].tap()
        XCTAssertTrue(app.staticTexts["Maria"].waitForExistence(timeout: 10),
                      "The people sheet on the Map tab lists Maria")
        XCTAssertTrue(app.buttons["Notebook"].exists, "The tab bar stays put on the Map tab")
    }
}
