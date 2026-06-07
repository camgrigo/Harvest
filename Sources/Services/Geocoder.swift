import Foundation
import CoreLocation
import MapKit

/// Turns free-text into a map coordinate. Tries strict address geocoding first, then falls
/// back to a natural-language place search (handles partial addresses and place names like
/// "the community center on 5th"). Offline-tolerant: returns nil if nothing is found.
enum AddressGeocoder {
    static func coordinate(for address: String) async -> CLLocationCoordinate2D? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 2 else { return nil }

        // 1. Structured address geocoding.
        if let request = MKGeocodingRequest(addressString: trimmed),
           let mapItems = try? await request.mapItems,
           let coordinate = mapItems.first?.location.coordinate {
            return coordinate
        }

        // 2. Natural-language fallback for partial addresses / named places.
        let search = MKLocalSearch.Request()
        search.naturalLanguageQuery = trimmed
        if let response = try? await MKLocalSearch(request: search).start(),
           let coordinate = response.mapItems.first?.location.coordinate {
            return coordinate
        }

        return nil
    }

    /// Reverse geocodes a coordinate into a human-readable address. Returns "" if unavailable.
    static func address(for coordinate: CLLocationCoordinate2D) async -> String {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let request = MKReverseGeocodingRequest(location: location),
              let items = try? await request.mapItems else { return "" }
        return items.first?.address?.fullAddress ?? ""
    }
}
