import XCTest
import SwiftData
@testable import ReturnVisitNotebook

/// Tests the data engine against an in-memory store: person matching, due filtering, and the
/// apply pipeline that turns a parsed message into saved records.
@MainActor
final class NotebookEngineTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Person.self, JournalEntry.self, ChatMessage.self, configurations: config
        )
        return ModelContext(container)
    }

    private func allPeople(_ context: ModelContext) -> [Person] {
        (try? context.fetch(FetchDescriptor<Person>())) ?? []
    }

    // MARK: Person matching

    func testFindOrCreateIsIdempotentCaseInsensitive() throws {
        let context = try makeContext()
        let first = NotebookEngine.findOrCreatePerson(named: "Maria", context: context)
        let second = NotebookEngine.findOrCreatePerson(named: "maria", context: context)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(allPeople(context).count, 1)
    }

    func testExistingPersonFuzzyMatch() throws {
        let context = try makeContext()
        context.insert(Person(name: "Maria Lopez"))
        XCTAssertNotNil(NotebookEngine.existingPerson(named: "Maria", context: context))
        XCTAssertNil(NotebookEngine.existingPerson(named: "Roberto", context: context))
    }

    // MARK: Due filtering

    func testDuePeopleIncludesOverdueAndUpcomingExcludesFarAndArchived() throws {
        let context = try makeContext()
        let cal = Calendar.current

        let overdue = Person(name: "Overdue")
        overdue.nextVisitDate = cal.date(byAdding: .day, value: -2, to: .now)

        let soon = Person(name: "Soon")
        soon.nextVisitDate = cal.date(byAdding: .day, value: 3, to: .now)

        let far = Person(name: "Far")
        far.nextVisitDate = cal.date(byAdding: .day, value: 30, to: .now)

        let archived = Person(name: "Archived")
        archived.nextVisitDate = cal.date(byAdding: .day, value: 1, to: .now)
        archived.isArchived = true

        let noReminder = Person(name: "NoReminder")

        [overdue, soon, far, archived, noReminder].forEach { context.insert($0) }

        let due = NotebookEngine.duePeople(context: context)
        let names = due.map(\.person.name)
        XCTAssertEqual(names, ["Overdue", "Soon"], "Sorted soonest-first, only within the week and not archived")
    }

    func testDueListEmptyMessage() throws {
        let context = try makeContext()
        XCTAssertTrue(NotebookEngine.dueList(context: context).contains("caught up"))
    }

    // MARK: Apply pipeline

    func testApplyLogVisitCreatesPersonAndEntry() async throws {
        let context = try makeContext()
        let parsed = ParsedMessage(
            intent: .logVisit,
            personName: "Maria",
            address: "",                 // empty avoids a network geocode in tests
            note: "Talked about why we suffer",
            followUpDate: "",
            interest: .interested
        )
        _ = await NotebookEngine.apply(parsed, original: "Met Maria, talked about why we suffer",
                                       assistant: Assistant(), context: context)

        let people = allPeople(context)
        XCTAssertEqual(people.count, 1)
        let maria = try XCTUnwrap(people.first)
        XCTAssertEqual(maria.name, "Maria")
        XCTAssertEqual(maria.interest, .interested)
        XCTAssertEqual(maria.entries.count, 1)
        XCTAssertTrue(maria.entries.first!.text.contains("suffer"))
    }

    func testApplyLogVisitSetsSmartReminderWhenNoneGiven() async throws {
        let context = try makeContext()
        let parsed = ParsedMessage(intent: .logVisit, personName: "John", address: "",
                                   note: "Friendly chat", followUpDate: "", interest: .unknown)
        _ = await NotebookEngine.apply(parsed, original: "Saw John", assistant: Assistant(), context: context)
        let john = try XCTUnwrap(allPeople(context).first)
        XCTAssertNotNil(john.nextVisitDate, "A logged visit should get a suggested follow-up")
        XCTAssertGreaterThan(john.nextVisitDate!, .now)
    }

    func testApplyListDueMentionsThePerson() async throws {
        let context = try makeContext()
        let p = Person(name: "Tomiko")
        p.nextVisitDate = Calendar.current.date(byAdding: .day, value: 2, to: .now)
        context.insert(p)

        let parsed = ParsedMessage(intent: .listDue, personName: "", address: "",
                                   note: "", followUpDate: "", interest: .unknown)
        let reply = await NotebookEngine.apply(parsed, original: "who's due",
                                               assistant: Assistant(), context: context)
        XCTAssertTrue(reply.contains("Tomiko"))
    }

    func testApplyNoteWithoutNameAsksForName() async throws {
        let context = try makeContext()
        let parsed = ParsedMessage(intent: .logVisit, personName: "", address: "",
                                   note: "had a nice chat", followUpDate: "", interest: .unknown)
        let reply = await NotebookEngine.apply(parsed, original: "had a nice chat",
                                               assistant: Assistant(), context: context)
        XCTAssertTrue(allPeople(context).isEmpty, "No person should be created without a name")
        XCTAssertTrue(reply.lowercased().contains("who"))
    }

    // MARK: Set address

    func testApplySetAddressAssignsAddressToPerson() async throws {
        let context = try makeContext()
        context.insert(Person(name: "Maria"))

        let parsed = ParsedMessage(intent: .setAddress, personName: "Maria",
                                   address: "12 Oak Street, Springfield", note: "",
                                   followUpDate: "", interest: .unknown)
        _ = await NotebookEngine.apply(parsed, original: "Maria's address is 12 Oak Street, Springfield",
                                       assistant: Assistant(), context: context)

        let maria = try XCTUnwrap(NotebookEngine.existingPerson(named: "Maria", context: context))
        XCTAssertEqual(maria.addressText, "12 Oak Street, Springfield")
    }

    func testApplySetAddressWithoutAddressPrompts() async throws {
        let context = try makeContext()
        let parsed = ParsedMessage(intent: .setAddress, personName: "", address: "",
                                   note: "", followUpDate: "", interest: .unknown)
        let reply = await NotebookEngine.apply(parsed, original: "what's the address",
                                               assistant: Assistant(), context: context)
        XCTAssertTrue(reply.lowercased().contains("address"))
    }

    // MARK: Editing a person

    func testEditPersonChangesInterestWithoutCreating() async throws {
        let context = try makeContext()
        context.insert(Person(name: "Maria"))

        let parsed = ParsedMessage(intent: .editPerson, personName: "Maria", address: "",
                                   note: "", followUpDate: "", interest: .studying)
        _ = await NotebookEngine.apply(parsed, original: "Change Maria's interest to studying",
                                       assistant: Assistant(), context: context)

        XCTAssertEqual(allPeople(context).count, 1, "Editing must not create a duplicate")
        let maria = try XCTUnwrap(NotebookEngine.existingPerson(named: "Maria", context: context))
        XCTAssertEqual(maria.interest, .studying)
    }

    func testEditPersonRenames() async throws {
        let context = try makeContext()
        context.insert(Person(name: "Maria"))

        let parsed = ParsedMessage(intent: .editPerson, personName: "Maria", address: "",
                                   note: "", followUpDate: "", interest: .unknown, newName: "Marie")
        _ = await NotebookEngine.apply(parsed, original: "Rename Maria to Marie",
                                       assistant: Assistant(), context: context)

        XCTAssertEqual(allPeople(context).count, 1)
        XCTAssertEqual(allPeople(context).first?.name, "Marie")
    }

    func testEditUnknownPersonDoesNotCreate() async throws {
        let context = try makeContext()
        let parsed = ParsedMessage(intent: .editPerson, personName: "Bob", address: "",
                                   note: "", followUpDate: "", interest: .studying)
        let reply = await NotebookEngine.apply(parsed, original: "Mark Bob as studying",
                                               assistant: Assistant(), context: context)
        XCTAssertTrue(allPeople(context).isEmpty, "Editing a stranger should not create them")
        XCTAssertTrue(reply.lowercased().contains("don't have a page"))
    }

    // MARK: Interest mapping

    func testInterestGuessMapping() {
        XCTAssertEqual(InterestGuess.studying.level, .studying)
        XCTAssertNil(InterestGuess.unknown.level)
    }
}
