import Foundation
import CoreLocation
import MapKit

/// Finds street addresses near a coordinate by reverse-geocoding a small ring of sample points
/// around it. Used to suggest neighbouring doors to log while walking a territory.
///
/// Approximate by nature — Apple has no "addresses near me" API, so we probe a handful of points
/// and keep the distinct addresses that come back, nearest-first.
enum NearbyAddresses {
    struct Suggestion: Identifiable, Hashable {
        let id = UUID()
        let address: String
        let latitude: Double
        let longitude: Double
        var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    }

    /// Normalised address key for de-duping (case/whitespace-insensitive).
    static func normalize(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reverse-geocodes the center plus a ring of nearby points, returning distinct addresses not
    /// already in `excluding`, ordered nearest-first and capped at `limit`. Bounded to a dozen
    /// lookups so it stays responsive.
    static func suggestions(around center: CLLocationCoordinate2D,
                            excluding: Set<String>,
                            limit: Int = 6) async -> [Suggestion] {
        var seen = excluding
        var found: [Suggestion] = []
        var requests = 0
        let origin = CLLocation(latitude: center.latitude, longitude: center.longitude)

        for point in samplePoints(around: center) {
            if found.count >= limit || requests >= 12 { break }
            requests += 1
            let loc = CLLocation(latitude: point.latitude, longitude: point.longitude)
            guard let request = MKReverseGeocodingRequest(location: loc),
                  let items = try? await request.mapItems,
                  let item = items.first,
                  let address = item.address?.fullAddress, !address.isEmpty else { continue }
            let key = normalize(address)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let c = item.location.coordinate
            found.append(Suggestion(address: address, latitude: c.latitude, longitude: c.longitude))
        }

        return found.sorted {
            origin.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
            < origin.distance(from: CLLocation(latitude: $1.latitude, longitude: $1.longitude))
        }
    }

    /// Live address search for what the user is typing, biased to a region around them. Returns
    /// distinct addressable matches (skips `excluding`), nearest-first to the region center.
    static func search(query: String,
                       near region: MKCoordinateRegion,
                       excluding: Set<String> = [],
                       limit: Int = 8) async -> [Suggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        request.region = region
        request.resultTypes = [.address, .pointOfInterest]
        guard let response = try? await MKLocalSearch(request: request).start() else { return [] }

        var seen = excluding
        var found: [Suggestion] = []
        for item in response.mapItems {
            guard let address = item.address?.fullAddress, !address.isEmpty else { continue }
            let key = normalize(address)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let c = item.location.coordinate
            found.append(Suggestion(address: address, latitude: c.latitude, longitude: c.longitude))
            if found.count >= limit { break }
        }

        let origin = CLLocation(latitude: region.center.latitude, longitude: region.center.longitude)
        return found.sorted {
            origin.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
            < origin.distance(from: CLLocation(latitude: $1.latitude, longitude: $1.longitude))
        }
    }

    /// The center, then 8 compass points at ~25 m and ~45 m — samples both sides of a street and
    /// a couple of doors along it.
    private static func samplePoints(around c: CLLocationCoordinate2D) -> [CLLocationCoordinate2D] {
        var pts = [c]
        for radius in [25.0, 45.0] {
            for bearing in stride(from: 0.0, to: 360.0, by: 45.0) {
                pts.append(offset(c, meters: radius, bearingDegrees: bearing))
            }
        }
        return pts
    }

    private static func offset(_ c: CLLocationCoordinate2D,
                               meters: Double, bearingDegrees: Double) -> CLLocationCoordinate2D {
        let bearing = bearingDegrees * .pi / 180
        let dLat = (meters * cos(bearing)) / 111_320.0
        let dLon = (meters * sin(bearing)) / (111_320.0 * cos(c.latitude * .pi / 180))
        return CLLocationCoordinate2D(latitude: c.latitude + dLat, longitude: c.longitude + dLon)
    }
}
