import XCTest
import SwiftData
import CoreLocation
@testable import Harvest

@MainActor
final class NotAtHomeExporterTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Person.self, JournalEntry.self, ChatMessage.self,
                 NotAtHome.self, Territory.self, DoNotCall.self,
                 ServicePlan.self, CongregationBoundary.self, ServiceSession.self,
                 OfflineMapRegion.self, VisitLog.self,
            configurations: config
        )
        return ModelContext(container)
    }

    func testPlainTextEmptyTerritory() throws {
        let context = try makeContext()
        let t = Territory(name: "Maple Block")
        context.insert(t)
        let text = NotAtHomeExporter.plainText(territory: t)
        XCTAssertTrue(text.contains("Territory: Maple Block"))
        XCTAssertTrue(text.contains("No addresses logged yet."))
    }

    func testPlainTextListsDoorsAndDoNotCalls() throws {
        let context = try makeContext()
        let t = Territory(name: "Oak St")
        context.insert(t)
        let door = NotAtHome(address: "12 Oak St")
        door.territory = t
        context.insert(door)
        let dnc = DoNotCall(address: "99 Oak St")
        dnc.territory = t
        context.insert(dnc)
        context.saveIfPossible()

        let text = NotAtHomeExporter.plainText(territory: t)
        XCTAssertTrue(text.contains("Not-at-homes (1):"))
        XCTAssertTrue(text.contains("12 Oak St"))
        XCTAssertTrue(text.contains("Do not call (1):"))
        XCTAssertTrue(text.contains("99 Oak St"))
    }

    func testCSVHeaderAndEscaping() throws {
        let context = try makeContext()
        let t = Territory(name: "Pine")
        context.insert(t)
        let door = NotAtHome(address: "Apt 5, \"The Lofts\"")
        door.territory = t
        context.insert(door)
        context.saveIfPossible()

        let csv = NotAtHomeExporter.csv(territory: t)
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.first, "Address,Type,Attempts,Last Tried")
        // Embedded quotes are doubled and the field is wrapped in quotes.
        XCTAssertTrue(csv.contains("\"Apt 5, \"\"The Lofts\"\"\",Not-at-home,1,"))
    }
}
