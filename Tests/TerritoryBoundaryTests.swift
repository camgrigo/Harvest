import XCTest
import SwiftData
import CoreLocation
@testable import Harvest

@MainActor
final class TerritoryBoundaryTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Territory.self, NotAtHome.self, DoNotCall.self, CongregationBoundary.self,
            configurations: config
        )
        return ModelContext(container)
    }

    func testTerritorySavesAndRecoversBoundary() throws {
        let context = try makeContext()
        let territory = Territory(name: "Zone 1")
        territory.setBoundary([
            CLLocationCoordinate2D(latitude: 40.0, longitude: -74.0),
            CLLocationCoordinate2D(latitude: 40.1, longitude: -74.1)
        ])
        context.insert(territory)
        try context.save()

        let recovered = try XCTUnwrap(try context.fetch(FetchDescriptor<Territory>()).first)
        XCTAssertEqual(recovered.coordinates.count, 2)
        XCTAssertEqual(recovered.coordinates[0].latitude, 40.0, accuracy: 0.0001)
        XCTAssertEqual(recovered.coordinates[1].longitude, -74.1, accuracy: 0.0001)
    }

    func testEmptyBoundaryDecodesToEmpty() throws {
        let territory = Territory(name: "Empty")
        XCTAssertTrue(territory.coordinates.isEmpty)
    }

    func testCongregationBoundarySetAndGet() throws {
        let boundary = CongregationBoundary()
        boundary.setBoundary([
            CLLocationCoordinate2D(latitude: 40.5, longitude: -74.5),
            CLLocationCoordinate2D(latitude: 40.6, longitude: -74.4)
        ])
        XCTAssertEqual(boundary.coordinates.count, 2)
        XCTAssertEqual(boundary.coordinates[0].latitude, 40.5, accuracy: 0.0001)
    }

    func testCongregationBoundaryPersists() throws {
        let context = try makeContext()
        let boundary = CongregationBoundary()
        boundary.setBoundary([CLLocationCoordinate2D(latitude: 1, longitude: 2)])
        context.insert(boundary)
        try context.save()
        let recovered = try XCTUnwrap(try context.fetch(FetchDescriptor<CongregationBoundary>()).first)
        XCTAssertEqual(recovered.coordinates.count, 1)
    }

    func testBoundaryCodingRoundTrip() {
        let coords = [
            CLLocationCoordinate2D(latitude: 12.5, longitude: -3.25),
            CLLocationCoordinate2D(latitude: -8.0, longitude: 100.0)
        ]
        let decoded = BoundaryCoding.decode(BoundaryCoding.encode(coords))
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[1].latitude, -8.0, accuracy: 0.0001)
        XCTAssertEqual(decoded[1].longitude, 100.0, accuracy: 0.0001)
    }

    // MARK: Due date

    func testTerritorySavesDueDate() throws {
        let context = try makeContext()
        let territory = Territory(name: "Zone 2")
        let due = Date.now.addingTimeInterval(86_400 * 7)
        territory.dueDate = due
        context.insert(territory)
        try context.save()

        let recovered = try XCTUnwrap(try context.fetch(FetchDescriptor<Territory>()).first)
        XCTAssertTrue(Calendar.current.isDate(recovered.dueDate ?? .distantPast, inSameDayAs: due))
    }

    func testDaysUntilDueIsDateRelative() {
        let cal = Calendar.current
        let now = Date.now
        let territory = Territory(name: "Due math")

        territory.dueDate = cal.date(byAdding: .day, value: 3, to: now)
        XCTAssertEqual(territory.daysUntilDue(asOf: now), 3)
        XCTAssertFalse(territory.isDue(asOf: now))

        territory.dueDate = cal.startOfDay(for: now)
        XCTAssertEqual(territory.daysUntilDue(asOf: now), 0)
        XCTAssertTrue(territory.isDue(asOf: now))

        territory.dueDate = cal.date(byAdding: .day, value: -2, to: now)
        XCTAssertEqual(territory.daysUntilDue(asOf: now), -2)
        XCTAssertTrue(territory.isDue(asOf: now))
    }

    func testNoDueDateIsNotDue() {
        let territory = Territory(name: "No due")
        XCTAssertNil(territory.daysUntilDue())
        XCTAssertFalse(territory.isDue())
    }
}
