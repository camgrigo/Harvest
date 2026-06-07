import Foundation
import SwiftData
import CoreLocation

/// A door where no one answered. Kept as a simple list you add to quickly while walking the
/// territory, so you can come back at a different time of day (per jw.org guidance on
/// not-at-homes). Deliberately minimal — just where, when you last tried, and how many times.
@Model
final class NotAtHome {
    var id: UUID
    var address: String
    var latitude: Double?
    var longitude: Double?
    var createdAt: Date
    /// When you most recently knocked. The time of day matters — vary it to catch people in.
    var lastTriedAt: Date
    /// How many times you've tried this door.
    var attemptCount: Int
    var note: String

    init(address: String,
         latitude: Double? = nil,
         longitude: Double? = nil,
         note: String = "",
         createdAt: Date = .now) {
        self.id = UUID()
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.createdAt = createdAt
        self.lastTriedAt = createdAt
        self.attemptCount = 1
        self.note = note
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Record another knock at this door.
    func markTriedAgain(at date: Date = .now) {
        attemptCount += 1
        lastTriedAt = date
    }
}
