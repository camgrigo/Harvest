import Foundation
import FoundationModels

/// What the user is trying to do with a given message.
@Generable
enum MessageIntent {
    /// Recording that a visit happened or a note about a person.
    case logVisit
    /// Asking for a recap of one person.
    case summarizePerson
    /// Asking who is due / who to see soon (a quick list).
    case listDue
    /// Asking for a fuller briefing/recap of everyone due this week.
    case summarizeDue
    /// Setting or changing a reminder only.
    case setReminder
    /// Looking up / setting an address: searching for a place or giving someone's address.
    case setAddress
    /// Correcting or updating an existing person's details (name, interest, reminder) — not a new visit.
    case editPerson
    /// Anything else (greeting, unclear).
    case other
}

/// The model's best guess at a person's interest, mapped to `InterestLevel` later.
@Generable
enum InterestGuess {
    case unknown
    case new
    case interested
    case studying
    case paused
}

/// The structured shape the on-device model fills in from a free-text message.
/// Unused fields come back as empty strings — we never force the user to provide them.
@Generable
struct ParsedMessage {
    @Guide(description: "What the user wants to do with this message.")
    var intent: MessageIntent

    @Guide(description: "The name of the person involved, or an empty string if none is mentioned.")
    var personName: String

    @Guide(description: "A street address or location for the person, or an empty string if none is mentioned.")
    var address: String

    @Guide(description: "What was discussed or any note worth keeping, in the user's own words. Empty if none.")
    var note: String

    @Guide(description: "The date to be reminded to return, in strict YYYY-MM-DD format. Empty string if the user did not say when to return.")
    var followUpDate: String

    @Guide(description: "The person's apparent level of interest, or unknown if not clear.")
    var interest: InterestGuess

    @Guide(description: "If the user wants to correct or change the person's name (a rename), the new name; otherwise an empty string.")
    var newName: String = ""
}

extension InterestGuess {
    var level: InterestLevel? {
        switch self {
        case .unknown: nil
        case .new: .new
        case .interested: .interested
        case .studying: .studying
        case .paused: .paused
        }
    }
}
