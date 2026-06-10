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
    @Query(sort: \CongregationBoundary.createdAt, order: .reverse)
    private var congregationBoundaries: [CongregationBoundary]
    @Query(sort: \VisitLog.timestamp) private var visitLogs: [VisitLog]
    @Environment(\.modelContext) private var context

    /// The active congregation boundary (most recently created), if any.
    private var congregationBoundary: CongregationBoundary? { congregationBoundaries.first }
    /// Territories that have a drawable polygon (at least a triangle).
    private var boundedTerritories: [Territory] { territories.filter { $0.coordinates.count >= 3 } }

    // Boundary styling: territory fill/stroke in one hue, congregation outline in a distinct one.
    private static let territoryFill = Color.blue.opacity(0.18)
    private static let territoryStroke = Color.blue.opacity(0.7)
    private static let congregationStroke = Color.purple.opacity(0.8)

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
    /// The map search sheet (jump to a person/territory by name).
    @State private var showSearch = false
    /// Pushes a detail page — kept separate from `selected`, which drives the on-map callout.
    @State private var openTarget: MapTarget?
    /// Driving route from you to the selected person: polyline points + ETA, shown on the map and
    /// in the callout.
    @State private var routeCoords: [CLLocationCoordinate2D] = []
    @State private var routeMinutes: Int?

    // Today's trail breadcrumb.
    @AppStorage("map.showBreadcrumb") private var showBreadcrumb = false

    /// Today's visited coordinates, oldest→newest, for the breadcrumb polyline.
    private var breadcrumbCoordinates: [CLLocationCoordinate2D] {
        VisitTracker.pointsToday(from: visitLogs).map(\.coordinate)
    }

    /// The default map view never zooms out past this radius around you.
    private static let maxDefaultRadius: CLLocationDistance = 30 * 1609.34   // 30 miles

    private var located: [Person] { people.filter { $0.coordinate != nil } }
    private var locatedTerritories: [Territory] { territories.filter { $0.coordinate != nil } }

    var body: some View {
        NavigationStack {
            map
                .overlay(alignment: .bottom) { bottomOverlay }
                .overlay(alignment: .topTrailing) { mapControlsCluster }
                .overlay(alignment: .leading) { dismissEdge }
                .overlay(alignment: .topLeading) { closeButton }
                .animation(.spring(duration: 0.3), value: selected)
                .navigationDestination(item: $openTarget) { target in
                    switch target {
                    case .person(let person):       PersonDetailView(person: person)
                    case .territory(let territory): TerritoryDetailView(territory: territory)
                    }
                }
                .onChange(of: selected) { _, newValue in handleSelect(newValue) }
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
                .sheet(isPresented: $showSearch) {
                    MapSearchView(people: people, territories: territories) { jump(to: $0) }
                }
                .task {
                    // Keep the breadcrumb store small: drop logs older than 30 days on open.
                    VisitTracker.purgeOld(from: context)
                }
        }
        .offset(x: dismissDrag)
    }

    // MARK: Map

    private var map: some View {
        MapReader { proxy in
            Map(position: $camera, selection: $selected) {
                UserAnnotation()
                // Territory boundaries: shaded polygons drawn under the markers so pins stay tappable.
                ForEach(boundedTerritories) { territory in
                    MapPolygon(coordinates: territory.coordinates)
                        .foregroundStyle(Self.territoryFill)
                        .stroke(Self.territoryStroke, lineWidth: 2)
                }
                // Congregation boundary: an outline in a distinct color, no fill.
                if let cong = congregationBoundary, cong.coordinates.count >= 2 {
                    MapPolyline(coordinates: cong.coordinates + [cong.coordinates[0]])
                        .stroke(Self.congregationStroke,
                                style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
                if !routeCoords.isEmpty {
                    MapPolyline(coordinates: routeCoords)
                        .stroke(routeColor, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
                // Today's trail: where you've been today, drawn behind the markers.
                if showBreadcrumb {
                    let trail = breadcrumbCoordinates
                    if trail.count >= 2 {
                        MapPolyline(coordinates: trail)
                            .stroke(Color.blue.opacity(0.5),
                                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [2, 6]))
                    }
                }
                ForEach(clustered) { item in
                    if case .single(let point) = item {
                        marker(for: point)
                    }
                    if case .cluster(_, let center, let members) = item {
                        Annotation("", coordinate: center) {
                            clusterBubble(count: members.count, center: center)
                        }
                    }
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
            Button { showSearch = true } label: { controlGlyph("magnifyingglass") }
                .accessibilityLabel("Search")
            Button { showLookChooser = true } label: { controlGlyph(mapLook.symbol) }
                .popover(isPresented: $showLookChooser) {
                    lookChooser.presentationCompactAdaptation(.popover)
                }
                .accessibilityLabel("Map style")
            Button { showBreadcrumb.toggle() } label: {
                controlGlyph(showBreadcrumb ? "point.topleft.down.curvedto.point.bottomright.up.fill"
                                            : "point.topleft.down.curvedto.point.bottomright.up")
            }
            .accessibilityLabel(showBreadcrumb ? "Hide today's trail" : "Show today's trail")
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
            // Hug the cards' height so the strip stays a bottom row and floats over the map —
            // a horizontal ScrollView otherwise greedily fills all vertical space. No backdrop;
            // each glass card provides its own surface.
            .fixedSize(horizontal: false, vertical: true)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.2), value: targets.count)
        }
    }

    // MARK: Selection · callout · route

    private func coordinate(of target: MapTarget) -> CLLocationCoordinate2D? {
        switch target {
        case .person(let p):    p.coordinate
        case .territory(let t): t.coordinate
        }
    }

    /// On selecting an item: center on it and, for a located person, draw the driving route.
    private func handleSelect(_ target: MapTarget?) {
        computeRoute(to: target)
        guard let target, let coordinate = coordinate(of: target) else { return }
        let span = visibleRegion?.span ?? MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        withAnimation(.easeInOut) {
            camera = .region(MKCoordinateRegion(center: coordinate, span: span))
        }
    }

    /// Pick a result from search: focus its pin (callout); if it has no location, just open it.
    private func jump(to target: MapTarget) {
        showSearch = false
        if coordinate(of: target) != nil {
            selected = target
        } else {
            openTarget = target
        }
    }

    private var routeColor: Color {
        if case .person(let p) = selected { return p.theme.color }
        return .blue
    }

    private func computeRoute(to target: MapTarget?) {
        routeCoords = []
        routeMinutes = nil
        guard let userLocation,
              case .person(let person)? = target,
              let dest = person.coordinate else { return }
        Task {
            if let result = await Self.route(from: userLocation, to: dest) {
                routeCoords = result.coords
                routeMinutes = result.minutes
            }
        }
    }

    /// Driving route from `user` to `dest` as Sendable coordinates + ETA minutes, so nothing
    /// non-Sendable crosses back to the main actor.
    private nonisolated static func route(from user: CLLocation, to dest: CLLocationCoordinate2D)
        async -> (coords: [CLLocationCoordinate2D], minutes: Int)? {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: user, address: nil)
        request.destination = MKMapItem(
            location: CLLocation(latitude: dest.latitude, longitude: dest.longitude), address: nil)
        request.transportType = .automobile
        guard let response = try? await MKDirections(request: request).calculate(),
              let route = response.routes.first else { return nil }
        let count = route.polyline.pointCount
        var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: count)
        route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
        return (coords, max(1, Int((route.expectedTravelTime / 60).rounded())))
    }

    private func openInMaps(_ coordinate: CLLocationCoordinate2D, name: String) {
        let item = MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
                             address: nil)
        item.name = name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }

    // MARK: Bottom overlay — callout or Nearby strip

    @ViewBuilder
    private var bottomOverlay: some View {
        if let selected {
            calloutCard(for: selected)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            nearbyStrip
        }
    }

    private func calloutCard(for target: MapTarget) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                calloutIcon(target)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(of: target))
                        .font(.headline).fontDesign(.serif).lineLimit(1)
                    Text(subtitle(of: target))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                Button { selected = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            HStack(spacing: 10) {
                Button { openTarget = target } label: {
                    Label("Open", systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                if let dest = coordinate(of: target) {
                    Button { openInMaps(dest, name: title(of: target)) } label: {
                        Label(routeMinutes.map { "\($0) min" } ?? "Directions", systemImage: "car.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func calloutIcon(_ target: MapTarget) -> some View {
        switch target {
        case .person(let p):
            let color: Color = p.isDue ? .red : p.theme.color
            Image(systemName: p.interest.symbol)
                .font(.headline)
                .foregroundStyle(color)
                .frame(width: 40, height: 40)
                .background(color.opacity(0.15), in: Circle())
        case .territory:
            Image("Territory")
                .resizable().scaledToFit()
                .frame(width: 22, height: 22)
                .foregroundStyle(.orange)
                .frame(width: 40, height: 40)
                .background(Color.orange.opacity(0.15), in: Circle())
        }
    }

    private func title(of target: MapTarget) -> String {
        switch target {
        case .person(let p):    p.name
        case .territory(let t): t.name
        }
    }

    private func subtitle(of target: MapTarget) -> String {
        switch target {
        case .person(let p):
            if let note = p.sortedEntries.last?.text, !note.isEmpty { return note }
            if !p.headline.isEmpty { return p.headline }
            return p.interest.label
        case .territory(let t):
            return territorySubtitle(t)
        }
    }

    // MARK: Clustering

    private var mapPoints: [MapPoint] {
        located.compactMap { person in
            person.coordinate.map { MapPoint(target: .person(person), coordinate: $0) }
        }
        + locatedTerritories.compactMap { territory in
            territory.coordinate.map { MapPoint(target: .territory(territory), coordinate: $0) }
        }
    }

    /// Buckets pins into a grid sized to the current zoom, so they merge into count bubbles when
    /// zoomed out and split back into individual markers when zoomed in.
    private var clustered: [MapItem] {
        let points = mapPoints
        guard let region = visibleRegion, points.count > 1 else { return points.map { .single($0) } }
        let grid = 7.0
        let cellLat = region.span.latitudeDelta / grid
        let cellLon = region.span.longitudeDelta / grid
        guard cellLat > 0, cellLon > 0 else { return points.map { .single($0) } }
        var buckets: [String: [MapPoint]] = [:]
        for point in points {
            let row = Int((point.coordinate.latitude / cellLat).rounded(.down))
            let col = Int((point.coordinate.longitude / cellLon).rounded(.down))
            buckets["\(row),\(col)", default: []].append(point)
        }
        return buckets.map { key, members in
            guard members.count > 1 else { return MapItem.single(members[0]) }
            let lat = members.map(\.coordinate.latitude).reduce(0, +) / Double(members.count)
            let lon = members.map(\.coordinate.longitude).reduce(0, +) / Double(members.count)
            return .cluster(id: key,
                            center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                            members: members)
        }
    }

    @MapContentBuilder
    private func marker(for point: MapPoint) -> some MapContent {
        switch point.target {
        case .person(let person):
            Marker(person.name, systemImage: person.interest.symbol, coordinate: point.coordinate)
                .tint(person.isDue ? .red : person.theme.color)
                .tag(MapTarget.person(person))
        case .territory(let territory):
            Marker(territory.name, image: "Territory", coordinate: point.coordinate)
                .tint(.orange)
                .tag(MapTarget.territory(territory))
        }
    }

    private func clusterBubble(count: Int, center: CLLocationCoordinate2D) -> some View {
        Text("\(count)")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(Color.accentColor.gradient, in: Circle())
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .onTapGesture { zoomToCluster(center) }
    }

    private func zoomToCluster(_ center: CLLocationCoordinate2D) {
        let span = visibleRegion?.span ?? MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
        let zoomed = MKCoordinateSpan(latitudeDelta: max(span.latitudeDelta / 3, 0.002),
                                      longitudeDelta: max(span.longitudeDelta / 3, 0.002))
        withAnimation(.easeInOut) {
            camera = .region(MKCoordinateRegion(center: center, span: zoomed))
        }
    }

    // MARK: Default region

    /// The opening region: centered on you, sized to include the farthest person within 30 miles
    /// (padded), but never zoomed out beyond a 30-mile radius. Falls back to the people's spread.
    private func defaultRegion() async -> MKCoordinateRegion? {
        // Frame both located people AND territories — a nearby territory should anchor the view
        // just as a person does.
        let pins = (located.compactMap(\.coordinate) + locatedTerritories.compactMap(\.coordinate))
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

/// A located item on the map (person or territory) — the unit of clustering.
private struct MapPoint {
    let target: MapTarget
    let coordinate: CLLocationCoordinate2D
}

/// Either a single pin or a merged cluster of nearby pins.
private enum MapItem: Identifiable {
    case single(MapPoint)
    case cluster(id: String, center: CLLocationCoordinate2D, members: [MapPoint])

    var id: String {
        switch self {
        case .single(let point):
            switch point.target {
            case .person(let p):    return "p-\(p.id)"
            case .territory(let t): return "t-\(t.id)"
            }
        case .cluster(let id, _, _):
            return "c-\(id)"
        }
    }
}

/// A searchable list of people and territories; picking one calls `onSelect` to jump the map there.
private struct MapSearchView: View {
    let people: [Person]
    let territories: [Territory]
    let onSelect: (MapTarget) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var matchedPeople: [Person] {
        query.isEmpty ? people
            : people.filter { $0.name.localizedCaseInsensitiveContains(query)
                || $0.headline.localizedCaseInsensitiveContains(query) }
    }
    private var matchedTerritories: [Territory] {
        query.isEmpty ? territories
            : territories.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !matchedPeople.isEmpty {
                    Section("People") {
                        ForEach(matchedPeople) { person in
                            Button { onSelect(.person(person)) } label: {
                                Label(person.name, systemImage: person.interest.symbol)
                            }
                        }
                    }
                }
                if !matchedTerritories.isEmpty {
                    Section("Territories") {
                        ForEach(matchedTerritories) { territory in
                            Button { onSelect(.territory(territory)) } label: {
                                Label(territory.name, systemImage: "map")
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Find a person or territory")
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } }
            }
        }
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
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)
        .task(id: cacheKey) { await loadETA() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yLabel)
    }

    private var a11yLabel: String {
        if let driveMinutes { return "\(title), \(driveMinutes) minutes by car" }
        return title
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
