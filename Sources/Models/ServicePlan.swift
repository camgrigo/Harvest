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

    init(date: Date = .now,
         durationMinutes: Int = 120,
         place: String = "",
         partner: String = "",
         note: String = "",
         createdAt: Date = .now) {
        self.id = UUID()
        self.date = date
        self.durationMinutes = durationMinutes
        self.place = place
        self.partner = partner
        self.note = note
        self.createdAt = createdAt
    }

    var end: Date { date.addingTimeInterval(TimeInterval(durationMinutes * 60)) }
    var isUpcoming: Bool { end >= .now }
}
