import Foundation
import SwiftData
import CoreLocation

/// An address you must not call on within a territory (the territory's do-not-call list).
/// Usually captured by scanning a territory sheet with the camera (OCR), then geocoded so the
/// territory can be placed on the map.
@Model
final class DoNotCall {
    var id: UUID
    var address: String
    var latitude: Double?
    var longitude: Double?
    var createdAt: Date
    var territory: Territory?

    init(address: String,
         latitude: Double? = nil,
         longitude: Double? = nil,
         createdAt: Date = .now) {
        self.id = UUID()
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.createdAt = createdAt
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
