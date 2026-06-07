import Foundation
import SwiftData

/// Single source of truth for turning a not-at-home door into a return visit (`Person`).
///
/// Contract: this **creates and inserts** the `Person` and its first `JournalEntry`, copying the
/// door's address, pin, and attempt history. It does **not** delete the door and does **not** save —
/// the caller owns deletion ("answered" → no longer a not-at-home) and `context.saveIfPossible()`.
enum NotAtHomePromotion {
    @discardableResult
    @MainActor
    static func promote(_ door: NotAtHome,
                        name: String = "",
                        note: String = "",
                        interest: InterestLevel = .new,
                        in context: ModelContext,
                        now: Date = .now) -> Person {
        let person = Person(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            addressText: door.address,
                            interest: interest,
                            createdAt: now)
        // Person.init forces coords to nil — copy the door's pin across explicitly.
        person.latitude = door.latitude
        person.longitude = door.longitude
        context.insert(person)

        // Preserve the attempt history in the first journal entry so it isn't lost on delete.
        let history = historyLine(for: door, now: now)
        let body = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = JournalEntry(date: now,
                                 text: body.isEmpty ? history : "\(body)\n\n\(history)",
                                 person: person)
        context.insert(entry)
        return person
    }

    /// Human-readable summary of how long this door took to answer.
    private static func historyLine(for door: NotAtHome, now: Date) -> String {
        if door.attemptCount <= 1 {
            return "Answered on the first visit."
        }
        let first = door.createdAt.formatted(.dateTime.month(.abbreviated).day().year())
        return "Reached after \(door.attemptCount) visits; first tried \(first)."
    }
}
