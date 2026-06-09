import XCTest
import SwiftData
@testable import Harvest

/// Tests promoting a not-at-home into a return visit (Person), and the address-normalisation used
/// for de-duping doors and suggestions.
@MainActor
final class PromotionTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Person.self, JournalEntry.self, ChatMessage.self,
                 NotAtHome.self, Territory.self, DoNotCall.self,
            configurations: config
        )
        return ModelContext(container)
    }

    func testPromoteCopiesAddressPinAndHistory() throws {
        let context = try makeContext()
        let door = NotAtHome(address: "12 Oak Street", latitude: 40.1, longitude: -74.2)
        context.insert(door)

        let person = NotAtHomePromotion.promote(door, name: "Maria", note: "Liked the tract",
                                                interest: .studying, in: context)

        XCTAssertEqual(person.name, "Maria")
        XCTAssertEqual(person.addressText, "12 Oak Street")
        XCTAssertEqual(person.interest, .studying)
        XCTAssertEqual(person.latitude, 40.1)
        XCTAssertEqual(person.longitude, -74.2)

        XCTAssertEqual(person.entries.count, 1)
        let text = try XCTUnwrap(person.entries.first?.text)
        XCTAssertTrue(text.contains("Liked the tract"))
        XCTAssertTrue(text.contains("Answered on the first visit."))

        // The routine does NOT delete the door — the caller owns that.
        XCTAssertEqual(try context.fetch(FetchDescriptor<NotAtHome>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Person>()).count, 1)
    }

    func testPromoteWithMultipleAttemptsSummarisesHistory() throws {
        let context = try makeContext()
        let door = NotAtHome(address: "5 Elm Ave")
        door.markTriedAgain()
        door.markTriedAgain()   // attemptCount == 3
        context.insert(door)

        let person = NotAtHomePromotion.promote(door, in: context)
        let text = try XCTUnwrap(person.entries.first?.text)
        XCTAssertTrue(text.contains("Reached after 3 visits"))
    }

    func testPromoteAllowsBlankName() throws {
        let context = try makeContext()
        let door = NotAtHome(address: "9 Pine Rd")
        context.insert(door)

        let person = NotAtHomePromotion.promote(door, name: "   ", in: context)
        XCTAssertEqual(person.name, "")
        XCTAssertEqual(person.interest, .new)   // default
    }

    func testAddressNormalisation() {
        XCTAssertEqual(NearbyAddresses.normalize("  12 Oak St  "), "12 oak st")
        XCTAssertEqual(NearbyAddresses.normalize("12 OAK ST"), "12 oak st")
        XCTAssertEqual(NearbyAddresses.normalize("12 Oak St"),
                       NearbyAddresses.normalize("12 oak st"))
    }
}
