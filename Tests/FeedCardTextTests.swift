import XCTest
import SwiftData
@testable import Harvest

/// Tests the shared card text helpers used by both the list rows and the masonry grid cards:
/// the person "due" label (today / tomorrow / in Nd / overdue / far-future date) and the
/// territory door-count subtitle (none / singular / plural / last-worked).
@MainActor
final class FeedCardTextTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Person.self, JournalEntry.self, ChatMessage.self, NotAtHome.self,
                 Territory.self, DoNotCall.self, ServicePlan.self,
            configurations: config
        )
        return ModelContext(container)
    }

    /// A date `offset` whole days from the start of today, matching personDueText's day math.
    private func day(_ offset: Int) -> Date {
        let start = Calendar.current.startOfDay(for: .now)
        return Calendar.current.date(byAdding: .day, value: offset, to: start)!
    }

    // MARK: personDueText

    func testDueTextIsNilWithoutADate() {
        XCTAssertNil(personDueText(Person(name: "Alex")))
    }

    func testDueTextToday() {
        let p = Person(name: "Alex"); p.nextVisitDate = day(0)
        XCTAssertEqual(personDueText(p), "Due today")
    }

    func testDueTextTomorrow() {
        let p = Person(name: "Alex"); p.nextVisitDate = day(1)
        XCTAssertEqual(personDueText(p), "Tomorrow")
    }

    func testDueTextWithinTwoWeeks() {
        let p = Person(name: "Alex"); p.nextVisitDate = day(3)
        XCTAssertEqual(personDueText(p), "in 3d")
    }

    func testDueTextOverdueSingularAndPlural() {
        let one = Person(name: "Alex"); one.nextVisitDate = day(-1)
        XCTAssertEqual(personDueText(one), "Overdue 1d")
        let many = Person(name: "Sam"); many.nextVisitDate = day(-4)
        XCTAssertEqual(personDueText(many), "Overdue 4d")
    }

    func testDueTextFarFutureFallsBackToACalendarDate() {
        let p = Person(name: "Alex"); p.nextVisitDate = day(40)
        let text = personDueText(p)
        XCTAssertNotNil(text)
        XCTAssertNotEqual(text, "in 40d")   // beyond two weeks → shows a month/day instead
    }

    // MARK: territorySubtitle

    func testSubtitleEmptyTerritory() throws {
        let context = try makeContext()
        let t = Territory(name: "Maple Ward")
        context.insert(t)
        XCTAssertEqual(territorySubtitle(t), "No not-at-homes yet")
    }

    func testSubtitleSingularThenPlural() throws {
        let context = try makeContext()
        let t = Territory(name: "Maple Ward")
        context.insert(t)
        t.doors.append(NotAtHome(address: "1 Elm St"))
        XCTAssertEqual(territorySubtitle(t), "1 not-at-home")
        t.doors.append(NotAtHome(address: "2 Elm St"))
        XCTAssertEqual(territorySubtitle(t), "2 not-at-homes")
    }

    func testSubtitleIncludesLastWorked() throws {
        let context = try makeContext()
        let t = Territory(name: "Maple Ward")
        context.insert(t)
        t.doors.append(NotAtHome(address: "1 Elm St"))
        t.lastWorkedAt = .now
        XCTAssertTrue(territorySubtitle(t).hasPrefix("1 not-at-home · last worked "))
    }
}
