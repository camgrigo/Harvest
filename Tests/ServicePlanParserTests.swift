import XCTest
@testable import Harvest

/// Tests the offline service-plan parser — the deterministic extractor behind the New Plan
/// smart-compose. Dates are checked relative to "today" so the suite never goes stale.
final class ServicePlanParserTests: XCTestCase {

    private let cal = Calendar.current

    // MARK: When (date + time)

    func testTimelessDayDefaultsToNineAM() throws {
        let parsed = ServicePlanParser.parse("Saturday")
        let date = try XCTUnwrap(parsed.date, "A weekday should resolve to a date")
        XCTAssertEqual(cal.component(.weekday, from: date), 7, "Should land on a Saturday")
        XCTAssertEqual(cal.component(.hour, from: date), 9, "A day with no time should default to 9 AM")
        XCTAssertGreaterThan(date, cal.startOfDay(for: .now))
    }

    func testExplicitTimeIsKept() throws {
        let parsed = ServicePlanParser.parse("tomorrow at 2pm")
        let date = try XCTUnwrap(parsed.date)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: .now)!
        XCTAssertTrue(cal.isDate(date, inSameDayAs: tomorrow), "Should be tomorrow")
        XCTAssertEqual(cal.component(.hour, from: date), 14, "2pm should be 14:00")
    }

    func testNoDateLeavesItNil() {
        XCTAssertNil(ServicePlanParser.parse("Bring extra magazines").date)
    }

    // MARK: Where / with

    func testPlaceExtraction() {
        XCTAssertEqual(ServicePlanParser.parse("Meet at the Kingdom Hall").place, "the Kingdom Hall")
    }

    func testPartnerExtraction() {
        let parsed = ServicePlanParser.parse("Field service with John")
        XCTAssertEqual(parsed.partner, "John")
        XCTAssertEqual(parsed.place, "")
    }

    func testPartnerKeepsConjoinedNames() {
        XCTAssertEqual(ServicePlanParser.parse("Out with John and Mary").partner, "John and Mary")
    }

    func testPartnerStopsBeforePlace() {
        let parsed = ServicePlanParser.parse("with John at the park")
        XCTAssertEqual(parsed.partner, "John")
        XCTAssertEqual(parsed.place, "the park")
    }

    func testPlaceAndPartnerTogether() {
        let parsed = ServicePlanParser.parse("at the library with Sarah")
        XCTAssertEqual(parsed.place, "the library")
        XCTAssertEqual(parsed.partner, "Sarah")
    }

    func testBareTimeIsNotTreatedAsPlace() {
        XCTAssertEqual(ServicePlanParser.parse("at 9am").place, "")
    }

    // MARK: Note remainder

    func testLeftoverProseBecomesNote() throws {
        let parsed = ServicePlanParser.parse("Saturday 9am at the Kingdom Hall with John, bring tracts")
        let date = try XCTUnwrap(parsed.date)
        XCTAssertEqual(cal.component(.weekday, from: date), 7)
        XCTAssertEqual(cal.component(.hour, from: date), 9)
        XCTAssertEqual(parsed.place, "the Kingdom Hall")
        XCTAssertEqual(parsed.partner, "John")
        XCTAssertTrue(parsed.note.contains("bring tracts"),
                      "Leftover prose should remain as the note, got: \(parsed.note)")
        XCTAssertFalse(parsed.note.contains("Kingdom Hall"),
                       "Recognized fragments should be stripped from the note")
    }

    func testEmptyInput() {
        let parsed = ServicePlanParser.parse("")
        XCTAssertNil(parsed.date)
        XCTAssertEqual(parsed.place, "")
        XCTAssertEqual(parsed.partner, "")
        XCTAssertEqual(parsed.note, "")
    }
}
