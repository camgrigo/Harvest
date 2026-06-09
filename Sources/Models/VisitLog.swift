import Foundation
import SwiftData
import CoreLocation

/// A single location visited today — a knocked door, a logged visit, or a location sample.
/// Drives the "today's trail" breadcrumb on the map. Lightweight on purpose so it doesn't bloat
/// the store; old entries can be purged (see `VisitTracker.purgeOld`).
@Model
final class VisitLog {
    var id: UUID
    var timestamp: Date
    var latitude: Double
    var longitude: Double
    /// Context tag: "not_at_home", "not_at_home_revisit", "return_visit", "location_sample", etc.
    /// Additive with a default for SwiftData lightweight migration.
    var context: String = "location_sample"

    init(coordinate: CLLocationCoordinate2D,
         timestamp: Date = .now,
         context: String = "location_sample") {
        self.id = UUID()
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.timestamp = timestamp
        self.context = context
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
