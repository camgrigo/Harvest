import XCTest
import SwiftData
@testable import ReturnVisitNotebook

/// Tests how the single message store is split into threads (general notebook vs. each person)
/// and how clearing a conversation hides messages without deleting them.
@MainActor
final class ChatThreadTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Person.self, JournalEntry.self, ChatMessage.self, NotAtHome.self,
            configurations: config
        )
        return ModelContext(container)
    }

    func testThreadsAreSeparatedByPerson() throws {
        let context = try makeContext()
        let maria = Person(name: "Maria")
        context.insert(maria)

        let general = ChatMessage(text: "general note", isFromUser: true)
        let mariaMsg = ChatMessage(text: "about maria", isFromUser: true, person: maria)
        context.insert(general)
        context.insert(mariaMsg)

        let all = [general, mariaMsg]
        XCTAssertEqual(ChatThread.messages(in: all, person: nil).map(\.text), ["general note"])
        XCTAssertEqual(ChatThread.messages(in: all, person: maria).map(\.text), ["about maria"])
    }

    func testClearHidesButKeepsMessages() throws {
        let context = try makeContext()
        let a = ChatMessage(date: Date(timeIntervalSince1970: 1), text: "one", isFromUser: true)
        let b = ChatMessage(date: Date(timeIntervalSince1970: 2), text: "two", isFromUser: false)
        context.insert(a)
        context.insert(b)
        let all = [a, b]

        let cleared = ChatThread.clear(all, person: nil)
        XCTAssertEqual(cleared, 2)

        // The active thread is now empty…
        XCTAssertTrue(ChatThread.messages(in: all, person: nil).isEmpty)
        // …but nothing was deleted, and history can be revealed.
        XCTAssertTrue(ChatThread.hasCleared(in: all, person: nil))
        XCTAssertEqual(ChatThread.messages(in: all, person: nil, includeCleared: true).count, 2)
    }

    func testClearingOneThreadLeavesOthersAlone() throws {
        let context = try makeContext()
        let maria = Person(name: "Maria")
        context.insert(maria)
        let general = ChatMessage(text: "general", isFromUser: true)
        let mariaMsg = ChatMessage(text: "maria", isFromUser: true, person: maria)
        context.insert(general)
        context.insert(mariaMsg)
        let all = [general, mariaMsg]

        ChatThread.clear(all, person: nil)
        XCTAssertTrue(ChatThread.messages(in: all, person: nil).isEmpty, "General thread cleared")
        XCTAssertEqual(ChatThread.messages(in: all, person: maria).count, 1, "Maria's thread untouched")
    }

    func testNewMessagesStartUncleared() {
        XCTAssertFalse(ChatMessage(text: "hi", isFromUser: true).isCleared)
        XCTAssertNil(ChatMessage(text: "hi", isFromUser: true).person)
    }
}
