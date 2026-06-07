import Foundation
import SwiftData

/// A single note about a person, in your own words. The raw `text` is the source of
/// truth; the extra fields are extras the chatbot fills in when it can, for nicer summaries.
@Model
final class JournalEntry {
    var date: Date
    var text: String
    var topic: String
    var scripture: String
    var publication: String
    var person: Person?
    /// Soft-delete timestamp. nil = active; once set, the note lives in "Recently Deleted" until
    /// it's purged 30 days later. Defaulted so existing rows lightweight-migrate.
    var deletedAt: Date? = nil

    init(date: Date = .now,
         text: String,
         topic: String = "",
         scripture: String = "",
         publication: String = "",
         person: Person? = nil) {
        self.date = date
        self.text = text
        self.topic = topic
        self.scripture = scripture
        self.publication = publication
        self.person = person
    }
}
