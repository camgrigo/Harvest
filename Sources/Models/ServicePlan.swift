import Foundation
import SwiftData

/// A personally-kept plan for a time in the ministry: when, where you'll meet, who you're going
/// with, and a note. Optionally mirrored to Apple Calendar. No sharing — just your own record.
@Model
final class ServicePlan {
    var id: UUID
    var date: Date
    var durationMinutes: Int
    var place: String
    var partner: String
    var note: String
    var createdAt: Date
    /// How (if at all) this plan repeats. Stored as a `RecurrenceKind` raw value. Defaults to
    /// "none" so existing records migrate cleanly (SwiftData lightweight migration).
    var recurrence: String = "none"

    init(date: Date = .now,
         durationMinutes: Int = 120,
         place: String = "",
         partner: String = "",
         note: String = "",
         recurrence: String = "none",
         createdAt: Date = .now) {
        self.id = UUID()
        self.date = date
        self.durationMinutes = durationMinutes
        self.place = place
        self.partner = partner
        self.note = note
        self.recurrence = recurrence
        self.createdAt = createdAt
    }

    var end: Date { date.addingTimeInterval(TimeInterval(durationMinutes * 60)) }
    var isUpcoming: Bool { end >= .now }

    /// Typed view over the stored `recurrence` string.
    var recurrenceKind: RecurrenceKind {
        get { RecurrenceKind(rawValue: recurrence) ?? .none }
        set { recurrence = newValue.rawValue }
    }

    /// The date of the next occurrence after this plan's `date`, or `nil` if it doesn't repeat.
    func nextOccurrence() -> Date? {
        RecurrenceKind(rawValue: recurrence)?.nextDate(after: date)
    }

    /// Upcoming occurrence dates for a recurring plan (including the original `date` when it's still
    /// in the future), oldest first, capped at `limit`. Empty for a non-recurring plan. Used to fan
    /// reminders out across the next several repeats.
    func upcomingOccurrences(limit: Int, now: Date = .now, calendar: Calendar = .current) -> [Date] {
        let kind = recurrenceKind
        guard kind != .none, limit > 0 else { return [] }
        var dates: [Date] = []
        var cursor = date
        if cursor > now { dates.append(cursor) }
        var guardCount = 0
        while dates.count < limit, guardCount < 500,
              let next = kind.nextDate(after: cursor, calendar: calendar) {
            if next > now { dates.append(next) }
            cursor = next
            guardCount += 1
        }
        return dates
    }

    /// Short body for this plan's reminder notification.
    var reminderSummary: String {
        if !partner.isEmpty { return "Field service with \(partner)" }
        if !place.isEmpty { return "Field service at \(place)" }
        return "Upcoming service plan"
    }
}

/// How a service plan repeats. Pure value type so the date math is easy to unit-test.
enum RecurrenceKind: String, Codable, CaseIterable {
    case none
    case weekly
    case biweekly
    case monthly

    var label: String {
        switch self {
        case .none: return "None"
        case .weekly: return "Weekly"
        case .biweekly: return "Every 2 weeks"
        case .monthly: return "Monthly"
        }
    }

    /// The next occurrence after `date`, or `nil` for `.none`. Uses the user's calendar so DST and
    /// month-length edge cases (e.g. Jan 31 + month) behave like the system Calendar app.
    func nextDate(after date: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .none:    return nil
        case .weekly:  return calendar.date(byAdding: .weekOfYear, value: 1, to: date)
        case .biweekly: return calendar.date(byAdding: .weekOfYear, value: 2, to: date)
        case .monthly: return calendar.date(byAdding: .month, value: 1, to: date)
        }
    }
}
