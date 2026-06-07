import Foundation
import SwiftData
import CoreLocation

/// One return visit — a person you met who showed interest and want to call back on.
@Model
final class Person {
    /// Stable id used for notification scheduling.
    var id: UUID
    var name: String
    var addressText: String
    var latitude: Double?
    var longitude: Double?
    var interestRaw: String
    var createdAt: Date
    /// When you next want to be reminded to return. nil = no reminder set.
    var nextVisitDate: Date?
    var isArchived: Bool
    /// A one-line gist kept fresh by the chatbot, shown in lists and on the map.
    var headline: String

    @Relationship(deleteRule: .cascade, inverse: \JournalEntry.person)
    var entries: [JournalEntry]

    init(name: String,
         addressText: String = "",
         interest: InterestLevel = .new,
         createdAt: Date = .now) {
        self.id = UUID()
        self.name = name
        self.addressText = addressText
        self.latitude = nil
        self.longitude = nil
        self.interestRaw = interest.rawValue
        self.createdAt = createdAt
        self.nextVisitDate = nil
        self.isArchived = false
        self.headline = ""
        self.entries = []
    }

    var interest: InterestLevel {
        get { InterestLevel(rawValue: interestRaw) ?? .new }
        set { interestRaw = newValue.rawValue }
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var sortedEntries: [JournalEntry] {
        entries.sorted { $0.date < $1.date }
    }

    /// True when a reminder is due today or overdue.
    var isDue: Bool {
        guard let nextVisitDate else { return false }
        return nextVisitDate <= Calendar.current.startOfDay(for: .now).addingTimeInterval(86_400)
    }
}
