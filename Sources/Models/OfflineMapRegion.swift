import Foundation
import SwiftData
import CoreLocation

/// A saved map region the user marked for offline use. Records the bounding box and metadata only.
///
/// IMPORTANT: This is a *preference* record, not a tile cache. Apple's MapKit EULA prohibits
/// persisting first-party tiles to disk, so actual tiles are fetched on demand and held in memory
/// for the session only (see `TileOverlayCache`). Marking a region lets us prefetch it best-effort.
@Model
final class OfflineMapRegion {
    var id: UUID
    var name: String
    var centerLatitude: Double
    var centerLongitude: Double
    var radiusMeters: Double
    var createdAt: Date

    init(name: String,
         center: CLLocationCoordinate2D,
         radiusMeters: Double,
         createdAt: Date = .now) {
        self.id = UUID()
        self.name = name
        self.centerLatitude = center.latitude
        self.centerLongitude = center.longitude
        self.radiusMeters = radiusMeters
        self.createdAt = createdAt
    }

    var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude)
    }
}
