import Foundation
import SwiftData
import CoreLocation

/// Shared helpers for encoding a polygon ring as the `boundaryData` storage string
/// ("lat,lon;lat,lon;…"), used by both `Territory` and `CongregationBoundary`.
enum BoundaryCoding {
    /// Decode a stored "lat,lon;lat,lon" string to coordinates. Empty/invalid → [].
    static func decode(_ data: String) -> [CLLocationCoordinate2D] {
        guard !data.isEmpty else { return [] }
        return data
            .split(separator: ";")
            .compactMap { pair in
                let parts = pair.split(separator: ",").map(String.init)
                guard parts.count == 2,
                      let lat = Double(parts[0]),
                      let lon = Double(parts[1]) else { return nil }
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
    }

    /// Encode coordinates to the "lat,lon;lat,lon" storage format.
    static func encode(_ coords: [CLLocationCoordinate2D]) -> String {
        coords
            .map { "\($0.latitude),\($0.longitude)" }
            .joined(separator: ";")
    }
}

/// A single shared polygon bounding the whole congregation's territory. In practice only one
/// exists at a time; the UI reads the most recently created one. Stored in the same lat,lon-pair
/// format as `Territory.boundaryData`, and rendered on the map in a distinct color.
@Model
final class CongregationBoundary {
    var id: UUID = UUID()
    var createdAt: Date = Date.now
    /// Polygon as comma-separated lat,lon pairs (same format as Territory.boundaryData).
    var boundaryData: String = ""

    init(boundaryData: String = "") {
        self.id = UUID()
        self.createdAt = .now
        self.boundaryData = boundaryData
    }

    /// Decode the boundary string to an array of coordinates.
    var coordinates: [CLLocationCoordinate2D] {
        BoundaryCoding.decode(boundaryData)
    }

    /// Encode an array of coordinates to the storage format.
    func setBoundary(_ coords: [CLLocationCoordinate2D]) {
        boundaryData = BoundaryCoding.encode(coords)
    }
}
