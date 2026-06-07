import XCTest
@testable import ReturnVisitNotebook

/// Tests the offline heuristic parser — the deterministic brain used when the on-device model
/// isn't available. Dates are checked relative to "today" so the suite never goes stale.
final class FallbackParserTests: XCTestCase {

    // MARK: Intent detection

    func testLogVisitIntent() {
        let parsed = FallbackParser.parse("Met Maria at 12 Oak Street, talked about hope.")
        XCTAssertEqual(parsed.intent, .logVisit)
    }

    func testSummarizePersonIntent() {
        XCTAssertEqual(FallbackParser.parse("Summarize Maria").intent, .summarizePerson)
        XCTAssertEqual(FallbackParser.parse("Give me a recap of John").intent, .summarizePerson)
    }

    func testListDueIntent() {
        XCTAssertEqual(FallbackParser.parse("Who should I see this week?").intent, .listDue)
    }

    func testSummarizeDueIntent() {
        XCTAssertEqual(FallbackParser.parse("Catch me up on everyone due this week").intent, .summarizeDue)
        XCTAssertEqual(FallbackParser.parse("Summarize everyone due").intent, .summarizeDue)
    }

    func testSetAddressIntent() {
        let possessive = FallbackParser.parse("Maria's address is 12 Oak Street")
        XCTAssertEqual(possessive.intent, .setAddress)
        XCTAssertEqual(possessive.personName, "Maria")
        XCTAssertEqual(possessive.address, "12 Oak Street")

        let search = FallbackParser.parse("Find 5 Elm Avenue")
        XCTAssertEqual(search.intent, .setAddress)
        XCTAssertEqual(search.address, "5 Elm Avenue")
        XCTAssertEqual(search.personName, "")
    }

    func testEditInterestIntent() {
        let parsed = FallbackParser.parse("Change Maria's interest to studying")
        XCTAssertEqual(parsed.intent, .editPerson)
        XCTAssertEqual(parsed.personName, "Maria")
        XCTAssertEqual(parsed.interest, .studying)
    }

    func testRenameIntent() {
        let parsed = FallbackParser.parse("Rename Maria to Marie")
        XCTAssertEqual(parsed.intent, .editPerson)
        XCTAssertEqual(parsed.personName, "Maria")
        XCTAssertEqual(parsed.newName, "Marie")
    }

    func testPlainNoteIsNotMistakenForEdit() {
        // Mentions "interested" but with no change verb — should still log a visit.
        XCTAssertEqual(FallbackParser.parse("Met Maria, she seemed interested").intent, .logVisit)
    }

    // MARK: Name detection

    func testNameAfterVisitVerb() {
        XCTAssertEqual(FallbackParser.parse("Visited Sarah today").personName, "Sarah")
        XCTAssertEqual(FallbackParser.parse("Met Maria at the door").personName, "Maria")
    }

    func testNoNameWhenNotCapitalized() {
        XCTAssertEqual(FallbackParser.parse("met someone interested").personName, "")
    }

    // MARK: Address detection

    func testAddressStopsAtStreetType() {
        // Should capture "5 Elm Avenue" and drop the trailing clause.
        let parsed = FallbackParser.parse("Saw John at 5 Elm Avenue, talked about the future")
        XCTAssertEqual(parsed.address, "5 Elm Avenue")
    }

    func testAddressWithStreetAbbreviation() {
        let parsed = FallbackParser.parse("Maria lives at 12 Oak St and was friendly")
        XCTAssertEqual(parsed.address, "12 Oak St")
    }

    func testNoAddressWhenNoStreetType() {
        XCTAssertEqual(FallbackParser.parse("Talked to Maria for an hour").address, "")
    }

    // MARK: Follow-up date detection

    func testFollowUpTomorrow() {
        let expected = DateFormatter.ymd.string(
            from: Calendar.current.date(byAdding: .day, value: 1, to: .now)!
        )
        XCTAssertEqual(FallbackParser.parse("Go back tomorrow").followUpDate, expected)
    }

    func testFollowUpInNDays() {
        let expected = DateFormatter.ymd.string(
            from: Calendar.current.date(byAdding: .day, value: 3, to: .now)!
        )
        XCTAssertEqual(FallbackParser.parse("Return in 3 days").followUpDate, expected)
    }

    func testFollowUpWeekdayIsFutureAndCorrectDay() throws {
        let result = FallbackParser.parse("Go back Saturday").followUpDate
        let date = try XCTUnwrap(DateFormatter.ymd.date(from: result), "Saturday should resolve to a date")
        XCTAssertGreaterThan(date, Calendar.current.startOfDay(for: .now))
        XCTAssertEqual(Calendar.current.component(.weekday, from: date), 7, "Should be a Saturday")
    }

    func testNoFollowUpWhenNoneMentioned() {
        XCTAssertEqual(FallbackParser.parse("Talked to Maria about hope").followUpDate, "")
    }
}
