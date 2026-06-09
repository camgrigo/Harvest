import Foundation
import SwiftData
import CoreLocation

/// A jw.org-style territory: a named area you're working, owning the not-at-home doors you log
/// while walking it and the do-not-call addresses on its card. Shown in the same feed as people,
/// and on the map as a single pin at the center of its addresses.
@Model
final class Territory {
    var id: UUID
    var name: String
    var createdAt: Date
    /// When you last added or re-tried a door here — surfaced as "last worked".
    var lastWorkedAt: Date?
    /// Optional explicit center, captured from your location ("use my area") or from scanning.
    /// When nil, `coordinate` falls back to the centroid of the doors + do-not-calls.
    var latitude: Double?
    var longitude: Double?
    /// Optional link to this territory in another app or on the web (a deep link, a shared map).
    var urlString: String?
    /// Optional attached image of the territory map (a photo or screenshot).
    var mapImageData: Data?
    /// Optional due date to return or turn in the territory (e.g. "next rotation").
    /// Additive property with a default for SwiftData lightweight migration.
    var dueDate: Date? = nil
    /// Polygon boundary as comma-separated lat,lon pairs, rings joined by ";".
    /// Example: "40.123,-74.456;40.124,-74.457;40.125,-74.458". Empty when unset.
    /// Decoded to [CLLocationCoordinate2D] on demand via `coordinates`. Stored as a String
    /// for SwiftData compatibility and to allow lightweight migration with a default.
    var boundaryData: String = ""

    @Relationship(deleteRule: .cascade, inverse: \NotAtHome.territory)
    var doors: [NotAtHome]
    @Relationship(deleteRule: .cascade, inverse: \DoNotCall.territory)
    var doNotCalls: [DoNotCall]

    init(name: String,
         latitude: Double? = nil,
         longitude: Double? = nil,
         createdAt: Date = .now) {
        self.id = UUID()
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.urlString = nil
        self.mapImageData = nil
        self.createdAt = createdAt
        self.lastWorkedAt = nil
        self.doors = []
        self.doNotCalls = []
    }

    /// The map-pin location: the explicit center if set, otherwise the average of every placed
    /// door and do-not-call. nil when there's nothing to place yet.
    var coordinate: CLLocationCoordinate2D? {
        if let latitude, let longitude {
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        let placed = doors.compactMap(\.coordinate) + doNotCalls.compactMap(\.coordinate)
        guard !placed.isEmpty else { return nil }
        let lat = placed.map(\.latitude).reduce(0, +) / Double(placed.count)
        let lon = placed.map(\.longitude).reduce(0, +) / Double(placed.count)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Decode the boundary string to an array of coordinates (empty when no boundary is set).
    var coordinates: [CLLocationCoordinate2D] {
        BoundaryCoding.decode(boundaryData)
    }

    /// Store a polygon ring as the boundary, encoding it to the storage format.
    func setBoundary(_ coords: [CLLocationCoordinate2D]) {
        boundaryData = BoundaryCoding.encode(coords)
    }

    var doorCount: Int { doors.count }

    /// Doors newest-first for the territory list.
    var sortedDoors: [NotAtHome] {
        doors.sorted { $0.createdAt > $1.createdAt }
    }

    /// Do-not-calls newest-first.
    var sortedDoNotCalls: [DoNotCall] {
        doNotCalls.sorted { $0.createdAt > $1.createdAt }
    }

    /// The attached link, if a valid one is stored.
    var url: URL? {
        guard let urlString, !urlString.isEmpty else { return nil }
        return URL(string: urlString)
    }

    /// Record that you worked this territory just now (adding or re-trying a door).
    func touch(at date: Date = .now) {
        lastWorkedAt = date
    }

    /// Whole-day count from `now` until the due date: 0 = due today, negative = overdue,
    /// positive = days remaining. nil when no due date is set. Pure + date-relative so it's testable.
    func daysUntilDue(asOf now: Date = .now, calendar: Calendar = .current) -> Int? {
        guard let dueDate else { return nil }
        let start = calendar.startOfDay(for: now)
        let end = calendar.startOfDay(for: dueDate)
        return calendar.dateComponents([.day], from: start, to: end).day
    }

    /// True when a due date is set and it's today or in the past.
    func isDue(asOf now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard let days = daysUntilDue(asOf: now, calendar: calendar) else { return false }
        return days <= 0
    }
}
