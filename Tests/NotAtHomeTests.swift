import XCTest
import SwiftData
@testable import Harvest

/// Tests the simple not-at-home list model: a new door starts at one attempt, and "tried again"
/// bumps the count and the last-tried time.
@MainActor
final class NotAtHomeTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Person.self, JournalEntry.self, ChatMessage.self, NotAtHome.self,
            configurations: config
        )
        return ModelContext(container)
    }

    func testNewDoorStartsWithOneAttempt() throws {
        let context = try makeContext()
        let door = NotAtHome(address: "14 Elm Street")
        context.insert(door)

        XCTAssertEqual(door.attemptCount, 1)
        XCTAssertEqual(door.lastTriedAt, door.createdAt)
        let all = try context.fetch(FetchDescriptor<NotAtHome>())
        XCTAssertEqual(all.count, 1)
    }

    func testTriedAgainIncrementsAndUpdatesTime() throws {
        let door = NotAtHome(address: "14 Elm Street",
                             createdAt: Date(timeIntervalSince1970: 1_000_000))
        let later = Date(timeIntervalSince1970: 1_100_000)
        door.markTriedAgain(at: later)

        XCTAssertEqual(door.attemptCount, 2)
        XCTAssertEqual(door.lastTriedAt, later)
        XCTAssertGreaterThan(door.lastTriedAt, door.createdAt)
    }

    func testCoordinateNilUntilLocated() throws {
        let door = NotAtHome(address: "14 Elm Street")
        XCTAssertNil(door.coordinate)
        door.latitude = 40.0
        door.longitude = -74.0
        XCTAssertNotNil(door.coordinate)
    }
}
