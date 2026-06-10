import XCTest
import SwiftData
import CoreLocation
@testable import Harvest

@MainActor
final class VisitTrackerTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Person.self, JournalEntry.self, ChatMessage.self,
                 NotAtHome.self, Territory.self, DoNotCall.self,
                 ServicePlan.self, CongregationBoundary.self, ServiceSession.self,
                 VisitLog.self,
            configurations: config
        )
        return ModelContext(container)
    }

    /// The pure filter keeps only same-day logs, ordered oldest→newest. Date-relative so it
    /// never goes stale.
    func testPointsTodayFiltersAndSorts() {
        let now = Date.now
        let cal = Calendar.current
        let logs = [
            VisitLog(coordinate: .init(latitude: 40.2, longitude: -74.2),
                     timestamp: now.addingTimeInterval(86_400), context: "tomorrow"),
            VisitLog(coordinate: .init(latitude: 40.0, longitude: -74.0),
                     timestamp: cal.startOfDay(for: now).addingTimeInterval(3_600), context: "early"),
            VisitLog(coordinate: .init(latitude: 40.1, longitude: -74.1),
                     timestamp: cal.startOfDay(for: now).addingTimeInterval(7_200), context: "late"),
            VisitLog(coordinate: .init(latitude: 40.3, longitude: -74.3),
                     timestamp: now.addingTimeInterval(-86_400), context: "yesterday"),
        ]
        let today = VisitTracker.pointsToday(from: logs, asOf: now)
        XCTAssertEqual(today.count, 2)
        XCTAssertEqual(today.map(\.context), ["early", "late"])   // chronological
    }

    /// Boundary: a log at exactly start-of-day counts as today; one a moment before does not.
    func testPointsTodayDayBoundary() {
        let now = Date.now
        let start = Calendar.current.startOfDay(for: now)
        let logs = [
            VisitLog(coordinate: .init(latitude: 1, longitude: 1), timestamp: start, context: "atStart"),
            VisitLog(coordinate: .init(latitude: 2, longitude: 2),
                     timestamp: start.addingTimeInterval(-1), context: "justBefore"),
        ]
        let today = VisitTracker.pointsToday(from: logs, asOf: now)
        XCTAssertEqual(today.map(\.context), ["atStart"])
    }

    /// logVisit persists, and todaysVisits fetches today's entries in order from SwiftData.
    func testLogAndFetchTodaysVisits() throws {
        let context = try makeContext()
        VisitTracker.logVisit(coordinate: .init(latitude: 40.0, longitude: -74.0),
                              context: "first", in: context)
        VisitTracker.logVisit(coordinate: .init(latitude: 40.1, longitude: -74.1),
                              context: "second", in: context)

        let coords = VisitTracker.todaysCoordinates(from: context)
        XCTAssertEqual(coords.count, 2)
        XCTAssertEqual(coords.first?.latitude, 40.0)
    }

    /// A log dated three days ago is excluded from today's fetch.
    func testFetchExcludesOlderDays() throws {
        let context = try makeContext()
        let old = VisitLog(coordinate: .init(latitude: 41.0, longitude: -75.0),
                           timestamp: Date.now.addingTimeInterval(-3 * 86_400))
        context.insert(old)
        context.saveIfPossible()

        XCTAssertTrue(VisitTracker.todaysVisits(from: context).isEmpty)
    }

    /// purgeOld removes logs past the cutoff and keeps recent ones.
    func testPurgeOldRemovesStaleLogs() throws {
        let context = try makeContext()
        let recent = VisitLog(coordinate: .init(latitude: 1, longitude: 1), timestamp: .now)
        let stale = VisitLog(coordinate: .init(latitude: 2, longitude: 2),
                             timestamp: Date.now.addingTimeInterval(-40 * 86_400))
        context.insert(recent)
        context.insert(stale)
        context.saveIfPossible()

        VisitTracker.purgeOld(olderThan: 30, from: context)

        let remaining = (try? context.fetch(FetchDescriptor<VisitLog>())) ?? []
        XCTAssertEqual(remaining.count, 1)
    }

    func testCoordinateRoundTrips() {
        let log = VisitLog(coordinate: .init(latitude: 37.7749, longitude: -122.4194))
        XCTAssertEqual(log.coordinate.latitude, 37.7749, accuracy: 1e-9)
        XCTAssertEqual(log.coordinate.longitude, -122.4194, accuracy: 1e-9)
    }
}
