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

    /// Shared with the bottom sheet, which `RootView` presents from the TabView so the tab bar
    /// floats over it. Holds the selection, nearby strip, route ETA, and push target.
    @Bindable var model: MapModel

    /// The active congregation boundary (most recently created), if any.
    private var congregationBoundary: CongregationBoundary? { congregationBoundaries.first }
    /// Territories that have a drawable polygon (at least a triangle).
    private var boundedTerritories: [Territory] { territories.filter { $0.coordinates.count >= 3 } }

    // Boundary styling: territory fill/stroke in one hue, congregation outline in a distinct one.
    private static let territoryFill = Color.blue.opacity(0.18)
    private static let territoryStroke = Color.blue.opacity(0.7)
    private static let congregationStroke = Color.purple.opacity(0.8)

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var dropped: DroppedPin?
    @State private var locationManager = CLLocationManager()
    @StateObject private var locator = CurrentLocationProvider()
    @State private var didSetDefaultCamera = false
    /// The map's current visible region, tracked so the Nearby strip reflects what's on screen.
    @State private var visibleRegion: MKCoordinateRegion?
    @AppStorage("map.look") private var mapLook: MapLook = .standard
    /// Driving route from you to the selected person: polyline points, drawn on the map. (The ETA
    /// minutes live on `model`, shared with the sheet's callout.)
    @State private var routeCoords: [CLLocationCoordinate2D] = []

    // Today's trail breadcrumb.
    @AppStorage("map.showBreadcrumb") private var showBreadcrumb = false

    /// Whether the Apple-Maps-style "Map Modes" card is up. While it's up the bottom sheet steps
    /// aside (via `model.suppressSheet`) so the card isn't occluded by it.
    @State private var showModes = false

    /// Drives the persistent bottom sheet. Presented from *within* the Map tab (not from `RootView`'s
    /// TabView) so the iOS 26 floating tab bar composites above it and stays tappable — a sheet
    /// presented at the TabView level instead covers the tab bar. Toggled with the tab's appearance.
    @State private var sheetUp = false

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
                .overlay(alignment: .bottomTrailing) {
                    MapControlPanel(mapLook: $mapLook,
                                    showBreadcrumb: $showBreadcrumb,
                                    onChooseStyle: openModes,
                                    onFrameAll: frameAll)
                }
                .overlay(alignment: .bottom) { modesOverlay }
                .animation(.spring(duration: 0.3), value: showModes)
                .animation(.spring(duration: 0.3), value: model.selected)
                .navigationDestination(item: $model.openTarget) { target in
                    switch target {
                    case .person(let person):       PersonDetailView(person: person)
                    case .territory(let territory): TerritoryDetailView(territory: territory)
                    }
                }
                .onChange(of: model.selected) { _, newValue in handleSelect(newValue) }
                // A pushed detail (or a popped one) toggles whether the sheet should stand aside.
                .onChange(of: model.openTarget) { _, target in
                    if target == nil { model.suppressSheet = false }
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
                    if model.userLocation == nil { model.userLocation = await locator.current() }
                }
                .sheet(item: $dropped) { pin in
                    LocationActionView(coordinate: pin.coordinate)
                }
                // A dropped pin gets its own sheet — step the map's bottom sheet aside while it's up.
                .onChange(of: dropped?.id) { _, _ in model.suppressSheet = (dropped != nil) }
                .task {
                    // Keep the breadcrumb store small: drop logs older than 30 days on open.
                    VisitTracker.purgeOld(from: context)
                }
        }
        // The persistent bottom sheet — presented here, inside the Map tab, so the floating tab bar
        // stays above it. `sheetUp` follows the tab's visibility; `suppressSheet` steps it aside for
        // the Map Modes card, a dropped-pin action, or a pushed detail.
        .sheet(isPresented: Binding(
            get: { sheetUp && !model.suppressSheet },
            set: { _ in }
        )) {
            MapBottomSheet(model: model, people: people, territories: territories)
                .presentationDetents([.height(120), .medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .large))
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
        }
        .onAppear { sheetUp = true }
        .onDisappear { sheetUp = false }
    }

    // MARK: Map

    private var map: some View {
        MapReader { proxy in
            Map(position: $camera, selection: $model.selected) {
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
                model.nearby = nearbyTargets(in: context.region)
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

    /// Re-frame the camera to show everyone (the opening overview).
    private func frameAll() {
        Task {
            if let region = await defaultRegion() {
                withAnimation(.easeInOut) { camera = .region(region) }
            }
        }
    }

    // MARK: Map Modes card

    /// The Map-style chooser, presented as a bottom card over a dimming scrim. Lives in the map's
    /// own layer (not a sheet/popover), so it isn't blocked by the bottom sheet — which we step
    /// aside while the card is up.
    @ViewBuilder
    private var modesOverlay: some View {
        if showModes {
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { closeModes() }
                MapModesCard(mapLook: $mapLook, onClose: closeModes)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func openModes() {
        model.suppressSheet = true
        showModes = true
    }

    private func closeModes() {
        showModes = false
        model.suppressSheet = false
    }

    // MARK: Nearby strip

    /// People + territories whose pin sits inside the given viewport, nearest the center first.
    private func nearbyTargets(in region: MKCoordinateRegion) -> [MapTarget] {
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


    // MARK: Selection · callout · route

    /// On selecting an item: center on it and, for a located person, draw the driving route.
    private func handleSelect(_ target: MapTarget?) {
        computeRoute(to: target)
        guard let target, let coordinate = coordinate(of: target) else { return }
        let span = visibleRegion?.span ?? MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        withAnimation(.easeInOut) {
            camera = .region(MKCoordinateRegion(center: coordinate, span: span))
        }
    }

    private var routeColor: Color {
        if case .person(let p) = model.selected { return p.theme.color }
        return .blue
    }

    private func computeRoute(to target: MapTarget?) {
        routeCoords = []
        model.routeMinutes = nil
        guard let userLocation = model.userLocation,
              case .person(let person)? = target,
              let dest = person.coordinate else { return }
        Task {
            if let result = await Self.route(from: userLocation, to: dest) {
                routeCoords = result.coords
                model.routeMinutes = result.minutes
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

/// The Apple-Maps-style bottom sheet for the Map tab: search over the nearby places, or — when one
/// is selected on the map — that place's details with Open / Directions.
///
/// Presented from the `TabView` in `RootView` (not from inside the Map tab) so the floating tab bar
/// stays on top of it. Shares the map's selection / nearby / route through `MapModel`.
struct MapBottomSheet: View {
    @Bindable var model: MapModel
    let people: [Person]
    let territories: [Territory]

    @State private var query = ""

    var body: some View {
        NavigationStack {
            Group {
                if let sel = model.selected {
                    placeDetail(sel)
                } else {
                    placeList
                }
            }
            .navigationTitle(model.selected.map(mapTargetTitle) ?? "Places")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.selected != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { model.selected = nil } label: { Label("Back", systemImage: "chevron.left") }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Search people & territories")
    }

    /// Nearby places, or name-filtered results while searching.
    private var results: [MapTarget] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.nearby }
        return people.filter { $0.name.lowercased().contains(q) }.map(MapTarget.person)
            + territories.filter { $0.name.lowercased().contains(q) }.map(MapTarget.territory)
    }

    @ViewBuilder
    private var placeList: some View {
        if results.isEmpty {
            ContentUnavailableView(query.isEmpty ? "Nothing nearby" : "No matches",
                                   systemImage: "mappin.slash")
        } else {
            List(results, id: \.self) { target in
                Button {
                    if query.isEmpty { model.selected = target } else { model.pick(target); query = "" }
                } label: {
                    HStack(spacing: 12) {
                        icon(target)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mapTargetTitle(target)).font(.body.weight(.semibold)).fontDesign(.serif)
                            Text(mapTargetSubtitle(target)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }

    private func placeDetail(_ target: MapTarget) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                icon(target)
                Text(mapTargetSubtitle(target)).font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button { model.open(target) } label: {
                    Label("Open", systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button { model.directions(target) } label: {
                    Label(model.routeMinutes.map { "\($0) min" } ?? "Directions", systemImage: "car.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func icon(_ target: MapTarget) -> some View {
        switch target {
        case .person(let p):
            let color: Color = p.isDue ? .red : p.theme.color
            Image(systemName: p.interest.symbol)
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.15), in: Circle())
        case .territory:
            Image("Territory").resizable().scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundStyle(.orange)
                .frame(width: 36, height: 36)
                .background(Color.orange.opacity(0.15), in: Circle())
        }
    }
}

#if DEBUG
#Preview("ExploreView") {
    let model = MapModel()
    model.nearby = PreviewData.people.map { MapTarget.person($0) }
    return ExploreView(model: model)
        .modelContainer(PreviewData.container)
}

#Preview("MapBottomSheet · list") {
    let model = MapModel()
    model.nearby = PreviewData.people.map { MapTarget.person($0) }
    return MapBottomSheet(model: model,
                          people: PreviewData.people,
                          territories: [PreviewData.territory])
        .modelContainer(PreviewData.container)
}

#Preview("MapBottomSheet · selected") {
    let model = MapModel()
    model.nearby = PreviewData.people.map { MapTarget.person($0) }
    model.selected = .person(PreviewData.person)
    return MapBottomSheet(model: model,
                          people: PreviewData.people,
                          territories: [PreviewData.territory])
        .modelContainer(PreviewData.container)
}
#endif
