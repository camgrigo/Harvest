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
    /// Glyph shown on the on-map look button and in the chooser tiles.
    var symbol: String {
        switch self {
        case .standard:  "map.fill"
        case .hybrid:    "square.2.layers.3d"
        case .satellite: "globe.americas.fill"
        }
    }
    /// Representative swatch color for the chooser tile.
    var swatch: Color {
        switch self {
        case .standard:  .green
        case .hybrid:    .teal
        case .satellite: .brown
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
    /// Your current location, used to show driving times in the Nearby strip.
    @State private var userLocation: CLLocation?
    @AppStorage("map.look") private var mapLook: MapLook = .standard
    /// Whether the Maps-style "choose a look" panel is open.
    @State private var showLookChooser = false
    /// When set (presented full-screen from the People tab), shows an X to dismiss.
    var onClose: (() -> Void)? = nil
    /// Live offset while swiping in from the left edge to dismiss the full-screen map.
    @State private var dismissDrag: CGFloat = 0

    /// The default map view never zooms out past this radius around you.
    private static let maxDefaultRadius: CLLocationDistance = 30 * 1609.34   // 30 miles

    private var located: [Person] { people.filter { $0.coordinate != nil } }
    private var locatedTerritories: [Territory] { territories.filter { $0.coordinate != nil } }

    var body: some View {
        NavigationStack {
            map
                .overlay(alignment: .bottom) { nearbyStrip }
                .overlay(alignment: .topTrailing) { mapControlsCluster }
                .overlay(alignment: .leading) { dismissEdge }
                .overlay(alignment: .topLeading) { closeButton }
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
                .task {
                    if userLocation == nil { userLocation = await locator.current() }
                }
                .sheet(item: $dropped) { pin in
                    LocationActionView(coordinate: pin.coordinate)
                }
        }
        .offset(x: dismissDrag)
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
                        .tint(person.isDue ? .red : person.theme.color)
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
            // A solid tap of feedback the moment a pin lands.
            .sensoryFeedback(trigger: dropped?.id) { _, newValue in
                newValue != nil ? .impact(flexibility: .solid, intensity: 0.7) : nil
            }
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

    // MARK: Look chooser

    /// The right-side control cluster (Apple Maps style): the map-style chooser plus a "show
    /// everything" button, sitting just below the system map controls.
    private var mapControlsCluster: some View {
        VStack(spacing: 12) {
            Button { showLookChooser = true } label: { controlGlyph(mapLook.symbol) }
                .popover(isPresented: $showLookChooser) {
                    lookChooser.presentationCompactAdaptation(.popover)
                }
                .accessibilityLabel("Map style")
            Button { frameAll() } label: { controlGlyph("scope") }
                .accessibilityLabel("Show everything")
        }
        .padding(.trailing, 12)
        .padding(.top, 96)
    }

    private func controlGlyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
            .background(.regularMaterial, in: Circle())
            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
    }

    /// Re-frame the camera to show everyone (the opening overview).
    private func frameAll() {
        Task {
            if let region = await defaultRegion() {
                withAnimation(.easeInOut) { camera = .region(region) }
            }
        }
    }

    /// A thin invisible strip down the left edge; a rightward drag here dismisses the full-screen
    /// map, following your finger and snapping back if you don't pull far enough.
    @ViewBuilder
    private var dismissEdge: some View {
        if onClose != nil {
            Color.clear
                .frame(width: 24)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(edgeDismissGesture)
        }
    }

    private var edgeDismissGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                dismissDrag = max(0, value.translation.width)
            }
            .onEnded { value in
                if value.translation.width > 100 {
                    onClose?()
                } else {
                    withAnimation(.spring) { dismissDrag = 0 }
                }
            }
    }

    /// Dismiss control, shown only when this map is presented full-screen (from the People tab).
    @ViewBuilder
    private var closeButton: some View {
        if let onClose {
            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
            }
            .padding(.leading, 12)
            .padding(.top, 8)
            .accessibilityLabel("Close map")
        }
    }

    /// A row of selectable look tiles, mirroring the Maps "Choose Map" panel.
    private var lookChooser: some View {
        HStack(spacing: 14) {
            ForEach(MapLook.allCases) { look in
                Button {
                    mapLook = look
                    showLookChooser = false
                } label: {
                    VStack(spacing: 7) {
                        Image(systemName: look.symbol)
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 60, height: 60)
                            .background(look.swatch.gradient,
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(mapLook == look ? Color.accentColor : .clear,
                                                  lineWidth: 3)
                            }
                        Text(look.label)
                            .font(.caption)
                            .fontWeight(mapLook == look ? .semibold : .regular)
                            .foregroundStyle(mapLook == look ? Color.accentColor : .primary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
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
                LazyHStack(spacing: 10) {
                    ForEach(targets, id: \.self) { target in
                        Button { selected = target } label: {
                            NearbyCard(target: target, userLocation: userLocation)
                        }
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

/// Session cache of driving ETAs (minutes), keyed by user→destination, so the strip doesn't
/// re-request the same route as it re-renders. Main-actor isolated.
@MainActor
enum DriveTimeCache {
    static var minutes: [String: Int] = [:]
    static func key(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.4f,%.4f", c.latitude, c.longitude)
    }
}

/// A compact card in the Map tab's Nearby strip: an icon, the item's name, and the driving time
/// from where you are now.
private struct NearbyCard: View {
    let target: MapTarget
    let userLocation: CLLocation?

    @State private var driveMinutes: Int?

    var body: some View {
        HStack(spacing: 10) {
            iconView
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .fontDesign(.serif)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                driveLabel
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 168, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 6, x: 0, y: 2)
        .task(id: cacheKey) { await loadETA() }
    }

    @ViewBuilder
    private var driveLabel: some View {
        if let driveMinutes {
            Label("\(driveMinutes) min", systemImage: "car.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if userLocation != nil, coordinate != nil {
            Label("…", systemImage: "car.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private var title: String {
        switch target {
        case .person(let p):    p.name
        case .territory(let t): t.name
        }
    }

    private var coordinate: CLLocationCoordinate2D? {
        switch target {
        case .person(let p):    p.coordinate
        case .territory(let t): t.coordinate
        }
    }

    /// Stable per (user, destination); also drives `.task(id:)` so the ETA loads once.
    private var cacheKey: String? {
        guard let user = userLocation, let dest = coordinate else { return nil }
        return "\(DriveTimeCache.key(user.coordinate))->\(DriveTimeCache.key(dest))"
    }

    private func loadETA() async {
        guard let key = cacheKey, let user = userLocation, let dest = coordinate else { return }
        if let cached = DriveTimeCache.minutes[key] { driveMinutes = cached; return }
        let minutes = await Self.drivingMinutes(from: user, to: dest)
            ?? Self.estimatedMinutes(from: user, to: dest)
        DriveTimeCache.minutes[key] = minutes
        driveMinutes = minutes
    }

    /// Real driving ETA via MapKit routing, in whole minutes.
    private nonisolated static func drivingMinutes(from user: CLLocation,
                                                   to dest: CLLocationCoordinate2D) async -> Int? {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: user, address: nil)
        request.destination = MKMapItem(
            location: CLLocation(latitude: dest.latitude, longitude: dest.longitude), address: nil)
        request.transportType = .automobile
        guard let eta = try? await MKDirections(request: request).calculateETA() else { return nil }
        return max(1, Int((eta.expectedTravelTime / 60).rounded()))
    }

    /// Offline fallback when routing is throttled/unavailable: straight-line distance at ~30 mph.
    private nonisolated static func estimatedMinutes(from user: CLLocation,
                                                     to dest: CLLocationCoordinate2D) -> Int {
        let meters = user.distance(from: CLLocation(latitude: dest.latitude, longitude: dest.longitude))
        return max(1, Int((meters / 13.4 / 60).rounded()))
    }

    @ViewBuilder
    private var iconView: some View {
        switch target {
        case .person(let p):
            let color: Color = p.isDue ? .red : p.theme.color
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
