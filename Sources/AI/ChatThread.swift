import Foundation

/// Pure helpers for splitting the single message store into conversation threads — the general
/// notebook (person == nil) and each person's own chat — and for clearing a thread without
/// deleting anything. Kept separate from the view so it can be unit tested.
enum ChatThread {

    /// Messages belonging to `person`'s thread (nil = the general notebook), oldest first.
    /// Cleared messages are left out unless `includeCleared` is true.
    static func messages(in all: [ChatMessage],
                         person: Person?,
                         includeCleared: Bool = false) -> [ChatMessage] {
        all.filter { belongs($0, to: person) && (includeCleared || !$0.isCleared) }
           .sorted { $0.date < $1.date }
    }

    /// True if `person`'s thread has any cleared (tucked-away) messages to reveal.
    static func hasCleared(in all: [ChatMessage], person: Person?) -> Bool {
        all.contains { belongs($0, to: person) && $0.isCleared }
    }

    /// Marks the thread's active messages as cleared — preserved, just hidden. Returns how many
    /// were affected so the caller can decide whether anything changed.
    @discardableResult
    static func clear(_ all: [ChatMessage], person: Person?) -> Int {
        let active = all.filter { belongs($0, to: person) && !$0.isCleared }
        for message in active { message.isCleared = true }
        return active.count
    }

    private static func belongs(_ message: ChatMessage, to person: Person?) -> Bool {
        message.person?.id == person?.id
    }
}
