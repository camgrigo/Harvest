import SwiftUI
import SwiftData
import MapKit
import CoreLocation
import UIKit

/// A transient pin dropped by touching and holding the map.
struct DroppedPin: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
}

/// A selectable thing on the map and in the feed: a person (return visit) or a territory
/// (house-to-house area). Shared by the map's selection and the list so a tap in either place
/// focuses the map and pushes the matching detail screen.
enum MapTarget: Hashable {
    case person(Person)
    case territory(Territory)
}

/// Map and people combined into one screen (Find My style): a full-bleed territory map with a
/// native bottom sheet of people that floats above it (background interaction stays enabled so
/// the map is still pannable). Tapping a pin opens that person in the sheet; touch and hold the
/// map to drop a new pin.
struct ExploreView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Person> { !$0.isArchived },
           sort: \Person.createdAt, order: .reverse) private var people: [Person]
    @Query(sort: \Territory.createdAt, order: .reverse) private var territories: [Territory]

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selected: MapTarget?
    @State private var dropped: DroppedPin?
    @State private var locationManager = CLLocationManager()
    @State private var detent: PresentationDetent = .medium
    @StateObject private var locator = CurrentLocationProvider()
    @State private var didSetDefaultCamera = false
    /// Live height of the bottom sheet, reported by the panel (kept so the map insets above it).
    @State private var sheetHeight: CGFloat = 168

    /// The default map view never zooms out past this radius around you.
    private static let maxDefaultRadius: CLLocationDistance = 30 * 1609.34   // 30 miles

    /// Resting "peek" height that keeps the search field, a row, and the chat bar visible.
    private static let peek: PresentationDetent = .height(168)

    /// Default detent when a person is selected — tall enough to show all their info without
    /// going full-screen, so the map pin stays visible above the sheet.
    private static let selectedDetent: PresentationDetent = .fraction(0.7)

    private var located: [Person] { people.filter { $0.coordinate != nil } }
    private var locatedTerritories: [Territory] { territories.filter { $0.coordinate != nil } }

    var body: some View {
        map
            .onAppear { locationManager.requestWhenInUseAuthorization() }
            .task {
                // On first load, frame everyone within 30 miles of you (capped at that radius).
                guard !didSetDefaultCamera else { return }
                didSetDefaultCamera = true
                if let region = await defaultRegion() {
                    withAnimation(.easeInOut) { camera = .region(region) }
                }
            }
            .onChange(of: selected) { _, target in
                focusMap(on: target)
            }
            .sheet(isPresented: .constant(true)) {
                PeoplePanelContent(people: people, territories: territories,
                                   selected: $selected, sheetHeight: $sheetHeight)
                    .presentationDetents([Self.peek, .medium, Self.selectedDetent, .large], selection: $detent)
                    .presentationBackgroundInteraction(.enabled(upThrough: Self.selectedDetent))
                    .presentationContentInteraction(.scrolls)
                    .presentationBackground(.regularMaterial)
                    .interactiveDismissDisabled()
                    .sheet(item: $dropped) { pin in
                        LocationActionView(coordinate: pin.coordinate)
                    }
            }
    }

    /// Move the camera + rest the sheet to suit the newly selected item: a person frames their
    /// pin at 70 %; a territory frames its area wider and opens the sheet tall (it's a work list).
    private func focusMap(on target: MapTarget?) {
        switch target {
        case .person(let person):
            if let coordinate = person.coordinate {
                withAnimation(.easeInOut) {
                    camera = .region(MKCoordinateRegion(
                        center: coordinate, latitudinalMeters: 400, longitudinalMeters: 400))
                }
                detent = Self.selectedDetent
            } else {
                detent = .large
            }
        case .territory(let territory):
            if let coordinate = territory.coordinate {
                withAnimation(.easeInOut) {
                    camera = .region(MKCoordinateRegion(
                        center: coordinate, latitudinalMeters: 1200, longitudinalMeters: 1200))
                }
            }
            detent = .large
        case .none:
            break
        }
    }

    /// The opening region: centered on you, sized to include the farthest person within
    /// 30 miles (with a little padding), but never zoomed out beyond a 30-mile radius.
    /// Falls back to the located people's spread when your location isn't available.
    private func defaultRegion() async -> MKCoordinateRegion? {
        let pins = located.compactMap(\.coordinate)
            .map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }

        let center: CLLocationCoordinate2D
        let radius: CLLocationDistance

        if let user = await locator.current() {
            center = user.coordinate
            let nearby = pins.map { $0.distance(from: user) }.filter { $0 <= Self.maxDefaultRadius }
            radius = (nearby.max() ?? 0)
        } else if !pins.isEmpty {
            // No location permission — frame the people instead, around their midpoint.
            let lat = pins.map(\.coordinate.latitude).reduce(0, +) / Double(pins.count)
            let lon = pins.map(\.coordinate.longitude).reduce(0, +) / Double(pins.count)
            center = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            let mid = CLLocation(latitude: lat, longitude: lon)
            radius = pins.map { $0.distance(from: mid) }.max() ?? Self.maxDefaultRadius
        } else {
            return nil   // nothing to show — keep the default user-location camera
        }

        // Clamp to the 30-mile cap, keep a sane floor, and pad so pins aren't at the edge.
        let clamped = min(max(radius, 1609.34), Self.maxDefaultRadius)
        let span = clamped * 2 * 1.2
        return MKCoordinateRegion(center: center, latitudinalMeters: span, longitudinalMeters: span)
    }

    // MARK: Map

    private var map: some View {
        MapReader { proxy in
            Map(position: $camera, selection: $selected) {
                UserAnnotation()
                ForEach(located) { person in
                    Marker(person.name,
                           systemImage: person.interest.symbol,
                           coordinate: person.coordinate!)
                        .tint(person.isDue ? .red : .blue)
                        .tag(MapTarget.person(person))
                }
                ForEach(locatedTerritories) { territory in
                    Marker(territory.name,
                           image: "Territory",
                           coordinate: territory.coordinate!)
                        .tint(.orange)
                        .tag(MapTarget.territory(territory))
                }
                if let dropped {
                    Marker("New pin", systemImage: "mappin", coordinate: dropped.coordinate)
                        .tint(.green)
                }
            }
            // Standard SwiftUI map controls (location, 2D/3D pitch, compass) — legible, system-styled.
            .mapControls {
                MapUserLocationButton()
                MapPitchToggle()
                MapCompass()
            }
            .gesture(dropPinGesture(proxy))
            // Keep the bottom clear of the resting sheet.
            .safeAreaPadding(.bottom, 168)
        }
    }

    /// Touch-and-hold, then read the press point and convert it to a map coordinate.
    private func dropPinGesture(_ proxy: MapProxy) -> some Gesture {
        LongPressGesture(minimumDuration: 0.4)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onEnded { value in
                if case .second(_, let drag?) = value,
                   let coordinate = proxy.convert(drag.location, from: .local) {
                    dropped = DroppedPin(coordinate: coordinate)
                }
            }
    }
}
