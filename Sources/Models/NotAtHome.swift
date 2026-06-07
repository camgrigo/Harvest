import Foundation
import SwiftData
import CoreLocation

/// A door where no one answered. Kept as a simple list you add to quickly while walking the
/// territory, so you can come back at a different time of day (per jw.org guidance on
/// not-at-homes). Records every knock time so we can suggest a better time to return.
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
    /// The territory this door belongs to.
    var territory: Territory?
    /// Timestamp of every knock, oldest→newest. Source of truth for time-of-day hints. Defaulted
    /// to [] so pre-existing rows lightweight-migrate; RootView.backfillAttemptTimes() seeds them.
    var attemptTimes: [Date] = []

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
        self.attemptTimes = [createdAt]
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Record another knock at this door (keeps count / lastTriedAt / times in lockstep).
    func markTriedAgain(at date: Date = .now) {
        attemptCount += 1
        lastTriedAt = date
        attemptTimes.append(date)
    }

    /// Undo a knock — decrement the try count and drop the most recent time. Floors at 1.
    func decrementTry() {
        guard attemptCount > 1 else { return }
        attemptCount -= 1
        if !attemptTimes.isEmpty { attemptTimes.removeLast() }
        lastTriedAt = attemptTimes.last ?? createdAt
    }

    /// Time-of-day suggestion for this door (e.g. "Always tried mornings — try evening").
    var returnHint: ReturnHint { ReturnHint(times: attemptTimes) }
}
