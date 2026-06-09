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
/// (house-to-house area).
enum MapTarget: Hashable {
    case person(Person)
    case territory(Territory)
}

/// Map appearance, chosen in Settings.
enum MapLook: String, CaseIterable, Identifiable {
    case standard, hybrid, satellite
    var id: String { rawValue }
    var label: String {
        switch self {
        case .standard:  "Standard"
        case .hybrid:    "Hybrid"
        case .satellite: "Satellite"
        }
    }
}

/// The Map tab: a full-bleed map of your located people and territories, with a horizontally
/// scrolling "Nearby" strip across the bottom showing whatever is currently in the map's viewport.
/// Tapping a pin or a Nearby card opens that page; touch and hold the map to drop a new pin.
struct ExploreView: View {
    @Query(filter: #Predicate<Person> { !$0.isArchived },
           sort: \Person.createdAt, order: .reverse) private var people: [Person]
    @Query(sort: \Territory.createdAt, order: .reverse) private var territories: [Territory]

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selected: MapTarget?
    @State private var dropped: DroppedPin?
    @State private var locationManager = CLLocationManager()
    @StateObject private var locator = CurrentLocationProvider()
    @State private var didSetDefaultCamera = false
    /// The map's current visible region, tracked so the Nearby strip reflects what's on screen.
    @State private var visibleRegion: MKCoordinateRegion?
    @AppStorage("map.look") private var mapLook: MapLook = .standard

    /// The default map view never zooms out past this radius around you.
    private static let maxDefaultRadius: CLLocationDistance = 30 * 1609.34   // 30 miles

    private var located: [Person] { people.filter { $0.coordinate != nil } }
    private var locatedTerritories: [Territory] { territories.filter { $0.coordinate != nil } }

    var body: some View {
        NavigationStack {
            map
                .overlay(alignment: .bottom) { nearbyStrip }
                .navigationDestination(item: $selected) { target in
                    switch target {
                    case .person(let person):       PersonDetailView(person: person)
                    case .territory(let territory): TerritoryDetailView(territory: territory)
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
                .onAppear { locationManager.requestWhenInUseAuthorization() }
                .task {
                    // On first load, frame everyone within 30 miles of you (capped at that radius).
                    guard !didSetDefaultCamera else { return }
                    didSetDefaultCamera = true
                    if let region = await defaultRegion() {
                        withAnimation(.easeInOut) { camera = .region(region) }
                    }
                }
                .sheet(item: $dropped) { pin in
                    LocationActionView(coordinate: pin.coordinate)
                }
        }
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
            .mapStyle(mapStyle)
            // Standard SwiftUI map controls (location, 2D/3D pitch, compass), tinted white.
            .mapControls {
                MapUserLocationButton()
                MapPitchToggle()
                MapCompass()
            }
            .tint(.white)
            .onMapCameraChange(frequency: .onEnd) { context in
                visibleRegion = context.region
            }
            .gesture(dropPinGesture(proxy))
            .ignoresSafeArea(edges: .bottom)
        }
    }

    /// The MapKit style for the chosen look (Standard / Hybrid / Satellite).
    private var mapStyle: MapStyle {
        switch mapLook {
        case .standard:  .standard(elevation: .flat)
        case .hybrid:    .hybrid(elevation: .flat)
        case .satellite: .imagery(elevation: .flat)
        }
    }

    // MARK: Nearby strip

    /// People + territories whose pin sits inside the current viewport, nearest the center first.
    private var nearbyTargets: [MapTarget] {
        guard let region = visibleRegion else { return [] }
        let center = CLLocation(latitude: region.center.latitude, longitude: region.center.longitude)
        func distance(_ c: CLLocationCoordinate2D) -> CLLocationDistance {
            CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: center)
        }
        let nearbyPeople = located
            .filter { region.contains($0.coordinate!) }
            .map { (MapTarget.person($0), distance($0.coordinate!)) }
        let nearbyTerritories = locatedTerritories
            .filter { region.contains($0.coordinate!) }
            .map { (MapTarget.territory($0), distance($0.coordinate!)) }
        return (nearbyPeople + nearbyTerritories).sorted { $0.1 < $1.1 }.map(\.0)
    }

    @ViewBuilder
    private var nearbyStrip: some View {
        let targets = nearbyTargets
        if !targets.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(targets, id: \.self) { target in
                        Button { selected = target } label: { NearbyCard(target: target) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .background(.bar)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.2), value: targets.count)
        }
    }

    // MARK: Default region

    /// The opening region: centered on you, sized to include the farthest person within 30 miles
    /// (padded), but never zoomed out beyond a 30-mile radius. Falls back to the people's spread.
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
            let lat = pins.map(\.coordinate.latitude).reduce(0, +) / Double(pins.count)
            let lon = pins.map(\.coordinate.longitude).reduce(0, +) / Double(pins.count)
            center = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            let mid = CLLocation(latitude: lat, longitude: lon)
            radius = pins.map { $0.distance(from: mid) }.max() ?? Self.maxDefaultRadius
        } else {
            return nil   // nothing to show — keep the default user-location camera
        }

        let clamped = min(max(radius, 1609.34), Self.maxDefaultRadius)
        let span = clamped * 2 * 1.2
        return MKCoordinateRegion(center: center, latitudinalMeters: span, longitudinalMeters: span)
    }

    // MARK: Drop pin

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

/// Simple viewport containment for the Nearby strip.
extension MKCoordinateRegion {
    func contains(_ c: CLLocationCoordinate2D) -> Bool {
        let latMin = center.latitude - span.latitudeDelta / 2
        let latMax = center.latitude + span.latitudeDelta / 2
        let lonMin = center.longitude - span.longitudeDelta / 2
        let lonMax = center.longitude + span.longitudeDelta / 2
        return c.latitude >= latMin && c.latitude <= latMax
            && c.longitude >= lonMin && c.longitude <= lonMax
    }
}

/// A compact card in the Map tab's Nearby strip.
private struct NearbyCard: View {
    let target: MapTarget

    var body: some View {
        HStack(spacing: 9) {
            iconView
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .fontDesign(.serif)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 200, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 6, x: 0, y: 2)
    }

    private var title: String {
        switch target {
        case .person(let p):    p.name
        case .territory(let t): t.name
        }
    }

    private var subtitle: String {
        switch target {
        case .person(let p):
            personDueText(p) ?? (p.headline.isEmpty ? p.interest.label : p.headline)
        case .territory(let t):
            territorySubtitle(t)
        }
    }

    @ViewBuilder
    private var iconView: some View {
        switch target {
        case .person(let p):
            let color: Color = p.isDue ? .red : .blue
            Image(systemName: p.interest.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.14), in: Circle())
        case .territory:
            Image("Territory")
                .resizable()
                .scaledToFit()
                .frame(width: 19, height: 19)
                .foregroundStyle(.orange)
                .frame(width: 34, height: 34)
                .background(Color.orange.opacity(0.15), in: Circle())
        }
    }
}
