import Foundation
import CoreLocation

/// Fetches a single current location on demand — used by the not-at-home list so one tap can
/// drop the nearest address. Requests when-in-use permission the first time if needed.
@MainActor
final class CurrentLocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    /// Returns the device's current location, or nil if permission is denied or it can't be read.
    func current() async -> CLLocation? {
        // Only one request in flight at a time.
        if let existing = continuation {
            existing.resume(returning: nil)
            continuation = nil
        }
        return await withCheckedContinuation { cont in
            self.continuation = cont
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                manager.requestLocation()
            case .notDetermined:
                manager.requestWhenInUseAuthorization()   // resume from the auth callback
            default:
                resume(nil)
            }
        }
    }

    private func resume(_ location: CLLocation?) {
        continuation?.resume(returning: location)
        continuation = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard continuation != nil else { return }
            switch self.manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                self.manager.requestLocation()
            case .notDetermined:
                break   // still waiting on the user
            default:
                resume(nil)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in resume(locations.last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in resume(nil) }
    }
}
