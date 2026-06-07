import XCTest
@testable import ReturnVisitNotebook

/// Tests the "best time to return" hint logic: time-of-day buckets, the fewest-tried suggestion,
/// and the four phrasing cases (single attempt, always-same-bucket, gap, no-gap). Uses a fixed
/// UTC calendar so bucketing is deterministic regardless of the test machine's timezone.
final class ReturnHintTests: XCTestCase {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func at(_ hour: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: hour, minute: 0))!
    }

    func testBuckets() {
        XCTAssertEqual(TimeBucket.of(at(9), calendar: cal), .morning)
        XCTAssertEqual(TimeBucket.of(at(14), calendar: cal), .afternoon)
        XCTAssertEqual(TimeBucket.of(at(19), calendar: cal), .evening)
        XCTAssertEqual(TimeBucket.of(at(23), calendar: cal), .night)
        XCTAssertEqual(TimeBucket.of(at(3), calendar: cal), .night)
    }

    func testNoAttemptsHasNoHint() {
        let hint = ReturnHint(times: [], calendar: cal)
        XCTAssertNil(hint.text)
        XCTAssertEqual(hint.priority, 0)
    }

    func testSingleAttemptIsLowPriorityNudge() {
        let hint = ReturnHint(times: [at(9)], calendar: cal)
        XCTAssertEqual(hint.priority, 1)
        XCTAssertEqual(hint.text, "Tried mornings — try evening")
        XCTAssertEqual(hint.symbol, "sunset")   // evening is the least-tried daytime bucket
    }

    func testAlwaysSameBucketIsHighPriority() {
        let hint = ReturnHint(times: [at(8), at(10), at(11)], calendar: cal)
        XCTAssertEqual(hint.priority, 3)
        XCTAssertEqual(hint.text, "Always tried mornings — try evening")
    }

    func testGapSuggestsAnUntriedDaytimeBucket() {
        // Tried morning + afternoon; evening never tried → suggests evening.
        let hint = ReturnHint(times: [at(9), at(14)], calendar: cal)
        XCTAssertEqual(hint.priority, 2)
        XCTAssertEqual(hint.text, "Try evening — not tried yet")
    }

    func testNoGapFallsBackToTryADifferentTime() {
        let hint = ReturnHint(times: [at(9), at(14), at(19)], calendar: cal)
        XCTAssertEqual(hint.priority, 1)
        XCTAssertEqual(hint.text, "Try a different time")
    }

    func testNightNeverSuggestedLiterally() {
        // Tried evening + afternoon + morning would give "no gap"; tried only nights → suggest
        // a daytime bucket, never "night".
        let hint = ReturnHint(times: [at(22), at(23)], calendar: cal)
        XCTAssertEqual(hint.text, "Always tried nights — try evening")
        XCTAssertNotEqual(hint.symbol, "moon")
    }
}
