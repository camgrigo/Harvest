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
}
