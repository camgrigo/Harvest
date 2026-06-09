import XCTest
import SwiftData
@testable import Harvest

/// Lesson + publication extraction in FallbackParser, and its application via NotebookEngine.
final class LessonParsingTests: XCTestCase {

    // MARK: FallbackParser — lesson number

    func testExtractLessonNumber() {
        XCTAssertEqual(FallbackParser.parse("Lesson 5 of Enjoy Life Forever!").studyLesson, "5")
    }

    func testExtractLessonWithAbbreviation() {
        XCTAssertEqual(FallbackParser.parse("lf lesson 2").studyLesson, "2")
    }

    func testNoLessonWhenNotMentioned() {
        XCTAssertEqual(FallbackParser.parse("Met Maria today").studyLesson, "")
    }

    // MARK: FallbackParser — publication

    func testDetectELF() {
        XCTAssertEqual(FallbackParser.parse("She's on lesson 3 of ELF").studyPublication, "Enjoy Life Forever!")
    }

    func testDetectLFF() {
        XCTAssertEqual(FallbackParser.parse("lff lesson 1").studyPublication, "Enjoy Life Forever!")
    }

    func testDetectBHS() {
        XCTAssertEqual(FallbackParser.parse("What Can the Bible Teach Us lesson 5").studyPublication,
                       "What Can the Bible Teach Us?")
    }

    func testNoPublicationWhenNotMentioned() {
        XCTAssertEqual(FallbackParser.parse("Lesson 2").studyPublication, "")
    }

    func testShortAbbreviationNotMatchedInsideWord() {
        // "ll" appears inside "really" — must not match the "Listen to God and Live Forever" key.
        XCTAssertEqual(FallbackParser.parse("we really talked").studyPublication, "")
    }

    // MARK: NotebookEngine application

    @MainActor
    func testApplyLessonToNewPerson() async throws {
        let context = try makeContext()
        let parsed = ParsedMessage(
            intent: .logVisit, personName: "Maria", address: "", note: "Started lesson 1",
            followUpDate: "", interest: .unknown, studyLesson: "1",
            studyPublication: "Enjoy Life Forever!")
        _ = await NotebookEngine.apply(parsed, original: "Met Maria, she started lesson 1",
                                       assistant: Assistant(), context: context)

        let maria = try XCTUnwrap((try context.fetch(FetchDescriptor<Person>())).first)
        XCTAssertEqual(maria.studyLesson, "1")
        XCTAssertEqual(maria.studyPublication, "Enjoy Life Forever!")
    }

    @MainActor
    func testUpdateLessonOnExistingPerson() async throws {
        let context = try makeContext()
        let maria = Person(name: "Maria")
        maria.studyLesson = "1"
        maria.studyPublication = "Enjoy Life Forever!"
        context.insert(maria)

        let parsed = ParsedMessage(
            intent: .logVisit, personName: "Maria", address: "", note: "Moved to lesson 2",
            followUpDate: "", interest: .unknown, studyLesson: "2",
            studyPublication: "Enjoy Life Forever!")
        _ = await NotebookEngine.apply(parsed, original: "Maria is on lesson 2 now",
                                       assistant: Assistant(), context: context)

        XCTAssertEqual(maria.studyLesson, "2")
    }

    // MARK: Helpers

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Person.self, JournalEntry.self, ChatMessage.self, configurations: config)
        return ModelContext(container)
    }
}
