import XCTest
import SwiftData
@testable import Harvest

/// Duplicate detection and person merging.
final class DuplicateDetectorTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Person.self, JournalEntry.self, ChatMessage.self, configurations: config)
        return ModelContext(container)
    }

    private func allPeople(_ context: ModelContext) -> [Person] {
        (try? context.fetch(FetchDescriptor<Person>())) ?? []
    }

    // MARK: Detection

    func testDetectExactNameDuplicate() {
        let dupes = DuplicateDetector.findDuplicates(in: [Person(name: "Maria"), Person(name: "maria")])
        XCTAssertEqual(dupes.count, 1)
    }

    func testDetectSubstringDuplicate() {
        let dupes = DuplicateDetector.findDuplicates(in: [Person(name: "Maria"), Person(name: "Maria Lopez")])
        XCTAssertEqual(dupes.count, 1)
    }

    func testDetectEditDistanceDuplicate() {
        let dupes = DuplicateDetector.findDuplicates(in: [Person(name: "Maria"), Person(name: "Mariah")])
        XCTAssertEqual(dupes.count, 1)
    }

    func testIgnoreArchivedDuplicates() {
        let p1 = Person(name: "Maria")
        let p2 = Person(name: "Maria")
        p2.isArchived = true
        XCTAssertEqual(DuplicateDetector.findDuplicates(in: [p1, p2]).count, 0)
    }

    func testNoFalsePositives() {
        XCTAssertEqual(DuplicateDetector.findDuplicates(in: [Person(name: "Maria"), Person(name: "John")]).count, 0)
    }

    func testShortNamesNotSubstringMatched() {
        // "Jo" is a substring of "John" but both are too short to flag by containment.
        XCTAssertEqual(DuplicateDetector.findDuplicates(in: [Person(name: "Jo"), Person(name: "John")]).count, 0)
    }

    // MARK: Merging

    @MainActor
    func testMergeMovesJournalEntries() async throws {
        let context = try makeContext()
        let source = Person(name: "Maria")
        let target = Person(name: "maria")
        let entry = JournalEntry(text: "Met today", person: source)
        context.insert(source); context.insert(target); context.insert(entry)

        _ = NotebookEngine.merge(source: source, into: target, context: context)

        XCTAssertEqual(allPeople(context).count, 1, "Source person is deleted")
        XCTAssertTrue(target.entries.contains { $0.text == "Met today" })
    }

    @MainActor
    func testMergeKeepsTargetAddressWhenPresent() async throws {
        let context = try makeContext()
        let source = Person(name: "Maria"); source.addressText = "12 Oak St"
        let target = Person(name: "maria"); target.addressText = "123 Elm"
        context.insert(source); context.insert(target)

        _ = NotebookEngine.merge(source: source, into: target, context: context)

        XCTAssertEqual(target.addressText, "123 Elm")
    }

    @MainActor
    func testMergeTakesSourceAddressWhenTargetEmpty() async throws {
        let context = try makeContext()
        let source = Person(name: "Maria"); source.addressText = "12 Oak St"
        let target = Person(name: "maria")
        context.insert(source); context.insert(target)

        _ = NotebookEngine.merge(source: source, into: target, context: context)

        XCTAssertEqual(target.addressText, "12 Oak St")
    }

    @MainActor
    func testMergeUpgradesInterest() async throws {
        let context = try makeContext()
        let source = Person(name: "Maria"); source.interest = .studying
        let target = Person(name: "maria"); target.interest = .interested
        context.insert(source); context.insert(target)

        _ = NotebookEngine.merge(source: source, into: target, context: context)

        XCTAssertEqual(target.interest, .studying)
    }

    @MainActor
    func testMergeKeepsEarlierReminder() async throws {
        let context = try makeContext()
        let cal = Calendar.current
        let source = Person(name: "Maria")
        source.nextVisitDate = cal.date(byAdding: .day, value: 2, to: .now)
        let target = Person(name: "maria")
        target.nextVisitDate = cal.date(byAdding: .day, value: 5, to: .now)
        context.insert(source); context.insert(target)

        _ = NotebookEngine.merge(source: source, into: target, context: context)

        let targetDate = try XCTUnwrap(target.nextVisitDate)
        XCTAssertLessThan(targetDate, try XCTUnwrap(cal.date(byAdding: .day, value: 3, to: .now)))
    }

    @MainActor
    func testMergeUpgradesStudyProgress() async throws {
        let context = try makeContext()
        let source = Person(name: "Maria")
        source.studyLesson = "5"; source.studyPublication = "Enjoy Life Forever!"
        let target = Person(name: "maria")
        target.studyLesson = "2"; target.studyPublication = "Enjoy Life Forever!"
        context.insert(source); context.insert(target)

        _ = NotebookEngine.merge(source: source, into: target, context: context)

        XCTAssertEqual(target.studyLesson, "5")
        XCTAssertEqual(target.studyPublication, "Enjoy Life Forever!")
    }

    @MainActor
    func testMergeFillsStudyWhenTargetHasNone() async throws {
        let context = try makeContext()
        let source = Person(name: "Maria")
        source.studyLesson = "3"; source.studyPublication = "Enjoy Life Forever!"
        let target = Person(name: "maria")
        context.insert(source); context.insert(target)

        _ = NotebookEngine.merge(source: source, into: target, context: context)

        XCTAssertEqual(target.studyLesson, "3")
        XCTAssertEqual(target.studyPublication, "Enjoy Life Forever!")
    }

    @MainActor
    func testMergeResultMessage() async throws {
        let context = try makeContext()
        let source = Person(name: "Maria"); source.interest = .studying
        let entry = JournalEntry(text: "Talked about hope", person: source)
        let target = Person(name: "maria")
        context.insert(source); context.insert(entry); context.insert(target)

        let result = NotebookEngine.merge(source: source, into: target, context: context)

        XCTAssertTrue(result.contains("maria"))
        XCTAssertTrue(result.contains("note"))
    }
}
