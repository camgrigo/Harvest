import XCTest
import SwiftData
@testable import Harvest

/// Monthly-rollup logic for service sessions, against an in-memory store. Assertions are
/// date-relative (built off `.now`) so they don't go stale.
@MainActor
final class ServiceSessionReportTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ServiceSession.self, Territory.self, configurations: config
        )
        return ModelContext(container)
    }

    private func thisMonth() -> (year: Int, month: Int) {
        let c = Calendar.current.dateComponents([.year, .month], from: .now)
        return (c.year!, c.month!)
    }

    func testTotalHoursSumsCompletedSessions() throws {
        let context = try makeContext()
        let (year, month) = thisMonth()

        let a = ServiceSession(startAt: .now)
        a.stop(at: a.startAt.addingTimeInterval(3600 + 1800)) // 1.5h
        let b = ServiceSession(startAt: .now)
        b.stop(at: b.startAt.addingTimeInterval(1800))         // 0.5h
        context.insert(a); context.insert(b)

        let hours = SessionReportEngine.totalHours(year: year, month: month, context: context)
        XCTAssertEqual(hours, 2.0, accuracy: 0.001)
        XCTAssertEqual(SessionReportEngine.sessionCount(year: year, month: month, context: context), 2)
    }

    func testActiveSessionExcludedFromReport() throws {
        let context = try makeContext()
        let (year, month) = thisMonth()
        context.insert(ServiceSession(startAt: .now)) // no end => active
        XCTAssertEqual(SessionReportEngine.sessionCount(year: year, month: month, context: context), 0)
        XCTAssertEqual(SessionReportEngine.totalHours(year: year, month: month, context: context), 0, accuracy: 0.001)
    }

    func testSoftDeletedExcludedFromReport() throws {
        let context = try makeContext()
        let s = ServiceSession(startAt: .now)
        s.stop(at: s.startAt.addingTimeInterval(7200)) // 2h
        context.insert(s)

        XCTAssertEqual(SessionReportEngine.thisMonthStats(context: context).count, 1)
        s.markDeleted()
        XCTAssertEqual(SessionReportEngine.thisMonthStats(context: context).count, 0)
    }

    func testOtherMonthExcluded() throws {
        let context = try makeContext()
        let (year, month) = thisMonth()
        let cal = Calendar.current
        // A session two months ago.
        let past = cal.date(byAdding: .month, value: -2, to: .now)!
        let s = ServiceSession(startAt: past)
        s.stop(at: past.addingTimeInterval(3600))
        context.insert(s)

        XCTAssertEqual(SessionReportEngine.sessionCount(year: year, month: month, context: context), 0)
    }

    func testThisMonthStatsMatchExplicitMonth() throws {
        let context = try makeContext()
        let (year, month) = thisMonth()
        let s = ServiceSession(startAt: .now)
        s.stop(at: s.startAt.addingTimeInterval(3600)) // 1h
        context.insert(s)

        let stats = SessionReportEngine.thisMonthStats(context: context)
        XCTAssertEqual(stats.year, year)
        XCTAssertEqual(stats.month, month)
        XCTAssertEqual(stats.hours, 1.0, accuracy: 0.001)
        XCTAssertEqual(stats.count, 1)
    }

    func testPurgeRemovesOldSoftDeletedOnly() throws {
        let context = try makeContext()
        let cal = Calendar.current

        let old = ServiceSession(startAt: .now)
        old.markDeleted(at: cal.date(byAdding: .day, value: -45, to: .now)!)
        let recent = ServiceSession(startAt: .now)
        recent.markDeleted(at: cal.date(byAdding: .day, value: -5, to: .now)!)
        let live = ServiceSession(startAt: .now)
        context.insert(old); context.insert(recent); context.insert(live)

        let removed = SessionReportEngine.purgeSoftDeleted(context: context)
        XCTAssertEqual(removed, 1)
        let remaining = (try? context.fetch(FetchDescriptor<ServiceSession>()))?.count
        XCTAssertEqual(remaining, 2)
    }

    func testDurationAndActiveHelpers() throws {
        let s = ServiceSession(startAt: .now)
        XCTAssertTrue(s.isActive)
        XCTAssertNil(s.durationSeconds)
        s.stop(at: s.startAt.addingTimeInterval(120))
        XCTAssertFalse(s.isActive)
        XCTAssertEqual(s.durationSeconds, 120)
    }
}
