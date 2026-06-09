import Foundation
import SwiftData

/// A line in a conversation. Persisted so your chat history survives between sessions.
/// A message belongs either to the general notebook (`person == nil`) or to one person's thread.
/// "Clearing" a chat sets `isCleared` rather than deleting — the words are kept, just tucked away.
@Model
final class ChatMessage {
    var date: Date
    var text: String
    var isFromUser: Bool
    /// Hidden from the active transcript when true, but never deleted.
    var isCleared: Bool = false
    /// The person this message belongs to, or nil for the general notebook chat.
    var person: Person? = nil
    /// When this assistant reply created or changed a person, the id of that person — so the chat can
    /// render a tappable card for it. Kept by id (not a relationship) so it's independent of the
    /// thread's `person` and survives that person later being deleted.
    var cardPersonID: UUID? = nil

    init(date: Date = .now,
         text: String,
         isFromUser: Bool,
         isCleared: Bool = false,
         person: Person? = nil,
         cardPersonID: UUID? = nil) {
        self.date = date
        self.text = text
        self.isFromUser = isFromUser
        self.isCleared = isCleared
        self.person = person
        self.cardPersonID = cardPersonID
    }
}
