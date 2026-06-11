import SwiftUI
import MapKit
import CoreLocation

/// Shared state for the Map tab's bottom sheet.
///
/// The sheet is presented from the `TabView` in `RootView` (not from inside the Map tab's content)
/// so the floating tab bar composites *on top of* the sheet — the Apple-Maps look. That split means
/// the map (in `ExploreView`) and the sheet (built in `RootView`) need a common place to read and
/// write the selection, the nearby strip, the route ETA, and the push target. This model is it.
@MainActor
@Observable
final class MapModel {
    /// The item focused on the map; drives the on-map callout and the sheet's detail view.
    var selected: MapTarget?
    /// People + territories currently in the map's viewport, nearest first.
    var nearby: [MapTarget] = []
    /// Your current location, for the directions ETA.
    var userLocation: CLLocation?
    /// Driving ETA to the selected person, in minutes.
    var routeMinutes: Int?
    /// Set when the user taps "Open" or picks an unlocated result; `ExploreView` observes this and
    /// pushes the detail inside its own NavigationStack.
    var openTarget: MapTarget?
    /// Steps the sheet aside while another presentation owns the screen (a dropped-pin action, or a
    /// pushed detail). Mirrors the old "one sheet per view" juggling.
    var suppressSheet = false

    /// Pick a result: focus its pin if it's on the map, otherwise just open it.
    func pick(_ target: MapTarget) {
        if coordinate(of: target) != nil { selected = target } else { openTarget = target }
    }

    /// Open a target's detail: step the sheet aside and push.
    func open(_ target: MapTarget) {
        suppressSheet = true
        openTarget = target
    }

    /// Hand the target off to Apple Maps for turn-by-turn directions.
    func directions(_ target: MapTarget) {
        guard let c = coordinate(of: target) else { return }
        openInMaps(c, name: mapTargetTitle(target))
    }
}

// MARK: - Shared MapTarget helpers
// Free functions so both ExploreView (the map) and MapBottomSheet (the sheet) can use them without
// duplicating logic across the now-split presentation.

func coordinate(of target: MapTarget) -> CLLocationCoordinate2D? {
    switch target {
    case .person(let p):    p.coordinate
    case .territory(let t): t.coordinate
    }
}

func mapTargetTitle(_ target: MapTarget) -> String {
    switch target {
    case .person(let p):    p.name
    case .territory(let t): t.name
    }
}

func mapTargetSubtitle(_ target: MapTarget) -> String {
    switch target {
    case .person(let p):
        if let note = p.sortedEntries.last?.text, !note.isEmpty { return note }
        if !p.headline.isEmpty { return p.headline }
        return p.interest.label
    case .territory(let t):
        return territorySubtitle(t)
    }
}

func openInMaps(_ coordinate: CLLocationCoordinate2D, name: String) {
    let item = MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
                         address: nil)
    item.name = name
    item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
}
