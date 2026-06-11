import SwiftUI
import SwiftData
import CoreLocation
import MapKit

/// The "add addresses to this territory" subsystem, lifted out of `TerritoryDetailView`:
/// the type-to-add live search, the ambient "Suggested nearby" set, and the actions that turn a
/// suggestion (or your current location) into a `NotAtHome` door. Holds the search state; the
/// territory / context / location dependencies are threaded through each method so the model needs
/// no environment at init and can be a plain `@State` value.
@MainActor
@Observable
final class TerritoryAddressSearch {
    /// What you're typing into the add field.
    var typed = ""
    /// Live matches for `typed`, near you.
    var liveResults: [NearbyAddresses.Suggestion] = []
    /// Addresses around you that aren't on the list yet (the "Suggested nearby" pool).
    var ambient: [NearbyAddresses.Suggestion] = []
    /// True while a live search is in flight.
    var searching = false
    /// True while "Add nearest address" is resolving.
    var isAdding = false
    /// The search region, centered on you (or the territory), set on appear.
    var region: MKCoordinateRegion?

    @ObservationIgnored private var searchTask: Task<Void, Never>?

    private static let distanceFormatter: MKDistanceFormatter = {
        let f = MKDistanceFormatter(); f.unitStyle = .abbreviated; return f
    }()

    func existingKeys(_ territory: Territory) -> Set<String> {
        Set(territory.doors.map { NearbyAddresses.normalize($0.address) })
    }

    /// Ambient suggestions that aren't already on the territory.
    func freshAmbient(_ territory: Territory) -> [NearbyAddresses.Suggestion] {
        let keys = existingKeys(territory)
        return ambient.filter { !keys.contains(NearbyAddresses.normalize($0.address)) }
    }

    func loadOnAppear(territory: Territory, location: CurrentLocationProvider) async {
        guard region == nil else { return }
        if let loc = await location.current() {
            region = MKCoordinateRegion(center: loc.coordinate,
                                        latitudinalMeters: 600, longitudinalMeters: 600)
            await loadAmbient(around: loc.coordinate, territory: territory)
        } else if let c = territory.coordinate {
            region = MKCoordinateRegion(center: c, latitudinalMeters: 800, longitudinalMeters: 800)
            await loadAmbient(around: c, territory: territory)
        }
    }

    private func loadAmbient(around coordinate: CLLocationCoordinate2D, territory: Territory) async {
        ambient = await NearbyAddresses.suggestions(around: coordinate, excluding: existingKeys(territory))
    }

    func runLiveSearch(_ value: String, territory: Territory) {
        searchTask?.cancel()
        let q = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { liveResults = []; searching = false; return }
        guard let region else { liveResults = []; return }
        searching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            let results = await NearbyAddresses.search(query: q, near: region,
                                                       excluding: existingKeys(territory))
            if Task.isCancelled { return }
            liveResults = results
            searching = false
        }
    }

    /// Add a suggestion as a new door. `confirm` reports the user-facing confirmation message.
    func addSuggestion(_ suggestion: NearbyAddresses.Suggestion,
                       territory: Territory, context: ModelContext,
                       confirm: (String) -> Void) {
        let key = NearbyAddresses.normalize(suggestion.address)
        guard !existingKeys(territory).contains(key) else { return }
        let door = NotAtHome(address: suggestion.address,
                             latitude: suggestion.latitude,
                             longitude: suggestion.longitude)
        context.insert(door)
        door.territory = territory
        territory.touch()
        VisitTracker.logVisit(
            coordinate: CLLocationCoordinate2D(latitude: suggestion.latitude,
                                               longitude: suggestion.longitude),
            context: "not_at_home", in: context)
        context.saveIfPossible()
        ambient.removeAll { NearbyAddresses.normalize($0.address) == key }
        liveResults.removeAll { NearbyAddresses.normalize($0.address) == key }
        confirm("Added \(suggestion.address).")
    }

    /// Resolve your current location to an address and add it (or mark an existing door tried again).
    /// `notify` reports a non-success message (e.g. location off); `confirm` reports success.
    func addNearest(territory: Territory, context: ModelContext, location: CurrentLocationProvider,
                    notify: (String) -> Void, confirm: (String) -> Void) async {
        isAdding = true
        defer { isAdding = false }

        guard let loc = await location.current() else {
            notify("Turn on location to add the nearest address.")
            return
        }
        let coordinate = loc.coordinate
        let address = await AddressGeocoder.address(for: coordinate)
        let resolved = address.isEmpty ? "Dropped location" : address

        if let existing = duplicate(of: resolved, near: coordinate, territory: territory) {
            existing.markTriedAgain()
            territory.touch()
            VisitTracker.logVisit(coordinate: coordinate, context: "not_at_home_revisit", in: context)
            context.saveIfPossible()
            confirm("Already on your list — marked tried again.")
            return
        }

        let door = NotAtHome(address: resolved,
                             latitude: coordinate.latitude,
                             longitude: coordinate.longitude)
        context.insert(door)
        door.territory = territory
        territory.touch()
        VisitTracker.logVisit(coordinate: coordinate, context: "not_at_home", in: context)
        context.saveIfPossible()
        confirm("Added \(resolved).")
    }

    private func duplicate(of address: String, near coordinate: CLLocationCoordinate2D,
                           territory: Territory) -> NotAtHome? {
        let key = NearbyAddresses.normalize(address)
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return territory.doors.first { door in
            if NearbyAddresses.normalize(door.address) == key { return true }
            if let c = door.coordinate {
                return CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: here) < 18
            }
            return false
        }
    }

    func distanceString(to suggestion: NearbyAddresses.Suggestion) -> String? {
        guard let region else { return nil }
        let origin = CLLocation(latitude: region.center.latitude, longitude: region.center.longitude)
        let there = CLLocation(latitude: suggestion.latitude, longitude: suggestion.longitude)
        return Self.distanceFormatter.string(fromDistance: origin.distance(from: there))
    }
}
