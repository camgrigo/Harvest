import XCTest
@testable import Harvest

/// Date math for repeating service plans. All assertions are relative to a reference date computed
/// with the same calendar used by the code under test, so they don't go stale over time.
final class RecurrenceTests: XCTestCase {

    private let cal = Calendar(identifier: .gregorian)
    private var reference: Date {
        cal.date(from: DateComponents(year: 2026, month: 6, day: 9, hour: 10))!
    }

    func testNoneHasNoNextOccurrence() {
        XCTAssertNil(RecurrenceKind.none.nextDate(after: reference, calendar: cal))
        let plan = ServicePlan(date: reference, recurrence: "none")
        XCTAssertNil(plan.nextOccurrence())
    }

    func testWeeklyAddsAWeek() {
        let next = RecurrenceKind.weekly.nextDate(after: reference, calendar: cal)
        XCTAssertEqual(next, cal.date(byAdding: .day, value: 7, to: reference))
    }

    func testBiweeklyAddsTwoWeeks() {
        let next = RecurrenceKind.biweekly.nextDate(after: reference, calendar: cal)
        XCTAssertEqual(next, cal.date(byAdding: .day, value: 14, to: reference))
    }

    func testMonthlyAddsAMonth() {
        let next = RecurrenceKind.monthly.nextDate(after: reference, calendar: cal)
        XCTAssertEqual(next, cal.date(byAdding: .month, value: 1, to: reference))
    }

    func testRecurrenceKindRoundTripsThroughRawValue() {
        let plan = ServicePlan(date: reference, recurrence: "weekly")
        XCTAssertEqual(plan.recurrenceKind, .weekly)
        plan.recurrenceKind = .monthly
        XCTAssertEqual(plan.recurrence, "monthly")
    }

    func testUnknownRawValueFallsBackToNone() {
        let plan = ServicePlan(date: reference, recurrence: "garbage")
        XCTAssertEqual(plan.recurrenceKind, .none)
        XCTAssertNil(plan.nextOccurrence())
    }

    // MARK: Occurrence expansion

    func testNonRecurringPlanProducesNoOccurrences() {
        let plan = ServicePlan(date: reference, recurrence: "none")
        let occurrences = RecurringOccurrence.upcoming(
            from: [plan], now: reference,
            horizon: DateComponents(month: 6), calendar: cal)
        XCTAssertTrue(occurrences.isEmpty)
    }

    func testWeeklyExpandsWithinHorizon() {
        // A weekly plan starting at `reference`, looking ahead 4 weeks → 4 future occurrences.
        let plan = ServicePlan(date: reference, recurrence: "weekly")
        let occurrences = RecurringOccurrence.upcoming(
            from: [plan], now: reference,
            horizon: DateComponents(weekOfYear: 4), calendar: cal)
        XCTAssertEqual(occurrences.count, 4)
        XCTAssertEqual(occurrences.first?.date,
                       cal.date(byAdding: .day, value: 7, to: reference))
    }

    func testOccurrencesAreSortedAndInFuture() {
        let weekly = ServicePlan(date: reference, recurrence: "weekly")
        let monthly = ServicePlan(date: reference, recurrence: "monthly")
        let now = reference
        let occurrences = RecurringOccurrence.upcoming(
            from: [monthly, weekly], now: now,
            horizon: DateComponents(month: 2), calendar: cal)
        XCTAssertFalse(occurrences.isEmpty)
        XCTAssertTrue(occurrences.allSatisfy { $0.date > now })
        XCTAssertEqual(occurrences, occurrences.sorted { $0.date < $1.date })
    }
}

extension RecurringOccurrence: Equatable {
    public static func == (lhs: RecurringOccurrence, rhs: RecurringOccurrence) -> Bool {
        lhs.date == rhs.date && lhs.plan === rhs.plan
    }
}
