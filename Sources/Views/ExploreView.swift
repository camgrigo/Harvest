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

/// One entry in the unified feed below the map.
enum FeedItem: Identifiable {
    case person(Person)
    case territory(Territory)

    var id: String {
        switch self {
        case .person(let p): "p-\(p.id)"
        case .territory(let t): "t-\(t.id)"
        }
    }
}

/// How the unified feed is ordered.
private enum SortMode: String, CaseIterable, Identifiable {
    case recent, nearest, due, name
    var id: String { rawValue }
    var label: String {
        switch self {
        case .recent:  "Recent"
        case .nearest: "Nearest"
        case .due:     "Due first"
        case .name:    "Name"
        }
    }
    var symbol: String {
        switch self {
        case .recent:  "clock"
        case .nearest: "location"
        case .due:     "bell"
        case .name:    "textformat"
        }
    }
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
                PeoplePanelContent(people: people, territories: territories, selected: $selected)
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
            // Native map controls — MapKit positions them within the safe area.
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

/// The unified feed shown inside the panel: people (return visits) and territories
/// (house-to-house areas). Tapping a row — or a map pin — sets `selected`, which both focuses
/// the map and pushes the matching detail screen within this stack.
private struct PeoplePanelContent: View {
    let people: [Person]
    let territories: [Territory]
    @Binding var selected: MapTarget?

    @Environment(\.modelContext) private var context
    @StateObject private var locator = CurrentLocationProvider()
    @State private var search = ""
    @State private var sort: SortMode = .recent
    @State private var showTerritories = true
    @State private var userLocation: CLLocation?
    @State private var addingTerritory = false
    @State private var personToDelete: Person?
    @State private var territoryToDelete: Territory?
    @State private var showingScan = false
    @State private var showNotebook = false
    @Namespace private var zoomNamespace

    private var allEmpty: Bool { people.isEmpty && territories.isEmpty }

    // MARK: Filtering / sorting

    private var filteredPeople: [Person] {
        people.filter { person in
            search.isEmpty
            || person.name.localizedCaseInsensitiveContains(search)
            || person.headline.localizedCaseInsensitiveContains(search)
        }
    }

    private var filteredTerritories: [Territory] {
        guard showTerritories else { return [] }
        return territories.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    /// People + territories merged, ordered by the chosen sort.
    private var feed: [FeedItem] {
        let items = filteredPeople.map(FeedItem.person) + filteredTerritories.map(FeedItem.territory)
        switch sort {
        case .recent:
            return items.sorted { createdAt(of: $0) > createdAt(of: $1) }
        case .nearest:
            guard let userLocation else {
                return items.sorted { createdAt(of: $0) > createdAt(of: $1) }
            }
            return items.sorted { distance(of: $0, from: userLocation) < distance(of: $1, from: userLocation) }
        case .due:
            return items.sorted { dueKey($0) < dueKey($1) }
        case .name:
            return items.sorted { nameKey($0).localizedCaseInsensitiveCompare(nameKey($1)) == .orderedAscending }
        }
    }

    private func dueKey(_ item: FeedItem) -> Date {
        switch item {
        case .person(let p): p.nextVisitDate ?? .distantFuture
        case .territory: .distantFuture
        }
    }

    private func nameKey(_ item: FeedItem) -> String {
        switch item {
        case .person(let p): p.name
        case .territory(let t): t.name
        }
    }

    private func createdAt(of item: FeedItem) -> Date {
        switch item {
        case .person(let p): p.createdAt
        case .territory(let t): t.createdAt
        }
    }

    private func coordinate(of item: FeedItem) -> CLLocationCoordinate2D? {
        switch item {
        case .person(let p): p.coordinate
        case .territory(let t): t.coordinate
        }
    }

    private func distance(of item: FeedItem, from origin: CLLocation) -> CLLocationDistance {
        guard let c = coordinate(of: item) else { return .greatestFiniteMagnitude }
        return CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: origin)
    }

    /// Abbreviated, locale-aware distance ("0.3 mi") shown on a card when we know where you are.
    private func distanceText(for coordinate: CLLocationCoordinate2D?) -> String? {
        guard let userLocation, let coordinate else { return nil }
        let meters = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            .distance(from: userLocation)
        return Self.distanceFormatter.string(fromDistance: meters)
    }

    private static let distanceFormatter: MKDistanceFormatter = {
        let formatter = MKDistanceFormatter()
        formatter.unitStyle = .abbreviated
        return formatter
    }()

    // MARK: Body

    var body: some View {
        NavigationStack {
            Group {
                if feed.isEmpty && !addingTerritory {
                    emptyState
                } else {
                    feedList
                }
            }
            // Inline search + sort + territory toggle, pinned above the list.
            .safeAreaInset(edge: .top, spacing: 0) { controlBar }
            // Tap-to-chat with the notebook, pinned to the bottom of the panel.
            .safeAreaInset(edge: .bottom) { notebookComposer }
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $selected) { target in
                switch target {
                case .person(let person):
                    PersonDetailView(person: person)
                        .navigationTransition(.zoom(sourceID: person.id, in: zoomNamespace))
                case .territory(let territory):
                    TerritoryDetailView(territory: territory)
                        .navigationTransition(.zoom(sourceID: territory.id, in: zoomNamespace))
                }
            }
            .navigationDestination(isPresented: $showNotebook) {
                ConversationView(person: nil, autofocusInput: true)
                    .navigationTitle("Notebook")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .sheet(isPresented: $showingScan) {
                ScanTerritoryView { territory in
                    showingScan = false
                    selected = .territory(territory)
                }
            }
            .confirmationDialog(
                "Delete \(personToDelete?.name ?? "")?",
                isPresented: Binding(get: { personToDelete != nil },
                                     set: { if !$0 { personToDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let p = personToDelete { deleteFromList(p) }
                    personToDelete = nil
                }
                Button("Cancel", role: .cancel) { personToDelete = nil }
            } message: {
                Text("All notes and visit history will be permanently removed.")
            }
            .confirmationDialog(
                "Delete \(territoryToDelete?.name ?? "")?",
                isPresented: Binding(get: { territoryToDelete != nil },
                                     set: { if !$0 { territoryToDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let t = territoryToDelete { deleteTerritoryFromList(t) }
                    territoryToDelete = nil
                }
                Button("Cancel", role: .cancel) { territoryToDelete = nil }
            } message: {
                Text("This territory and all its addresses will be permanently removed.")
            }
            // Fetch location once for distance labels + the Nearest sort.
            .task {
                if userLocation == nil { await refreshLocation() }
            }
        }
    }

    // MARK: Add

    /// Bottom composer: a leading add-menu, then a tap-to-chat field that opens the notebook
    /// scratchpad with the keyboard up. "New person" lands in that same scratchpad.
    private var notebookComposer: some View {
        HStack(spacing: 10) {
            Menu {
                Button {
                    showNotebook = true
                } label: { Label("New person", systemImage: "person.badge.plus") }
                Button {
                    withAnimation { addingTerritory = true }
                } label: { Label("New territory", systemImage: "map") }
                Button {
                    showingScan = true
                } label: { Label("Scan territory card", systemImage: "doc.text.viewfinder") }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
            }
            .accessibilityLabel("Add")

            Button {
                showNotebook = true
            } label: {
                HStack {
                    Text("Jot a note")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: List

    private var feedList: some View {
        List {
            if addingTerritory {
                AddTerritoryInline(
                    onCreated: { territory in
                        addingTerritory = false
                        selected = .territory(territory)
                    },
                    onCancel: { addingTerritory = false }
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
            if sort == .name {
                // Sorting by name splits the feed into People / Territories sections.
                let ppl = filteredPeople.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                let trs = filteredTerritories.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                if !ppl.isEmpty {
                    Section("People") {
                        ForEach(ppl) { styledRow(for: .person($0)) }
                    }
                }
                if !trs.isEmpty {
                    Section("Territories") {
                        ForEach(trs) { styledRow(for: .territory($0)) }
                    }
                }
            } else {
                ForEach(feed) { styledRow(for: $0) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func styledRow(for item: FeedItem) -> some View {
        row(for: item)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }

    @ViewBuilder
    private func row(for item: FeedItem) -> some View {
        switch item {
        case .person(let person):
            Button {
                selected = .person(person)
            } label: {
                PersonCard(person: person, distanceText: distanceText(for: person.coordinate))
            }
            .buttonStyle(.plain)
            .matchedTransitionSource(id: person.id, in: zoomNamespace)
            .contextMenu {
                Button(role: .destructive) {
                    personToDelete = person
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        case .territory(let territory):
            Button {
                selected = .territory(territory)
            } label: {
                TerritoryCard(territory: territory, distanceText: distanceText(for: territory.coordinate))
            }
            .buttonStyle(.plain)
            .matchedTransitionSource(id: territory.id, in: zoomNamespace)
            .contextMenu {
                Button(role: .destructive) {
                    territoryToDelete = territory
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            allEmpty ? "Nothing yet" : "No matches",
            systemImage: allEmpty ? "map" : "magnifyingglass",
            description: Text(emptyDescription)
        )
    }

    // MARK: Top controls

    /// Inline search, a sort menu, and a show/hide-territories toggle — pinned above the list.
    private var controlBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $search)
                    .textFieldStyle(.plain)
                    .submitLabel(.search)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .glassEffect(in: Capsule())

            Menu {
                Picker("Sort by", selection: $sort) {
                    ForEach(SortMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.symbol).tag(mode)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .frame(width: 40, height: 40)
                    .glassEffect(in: Circle())
            }
            .accessibilityLabel("Sort")

            Button {
                withAnimation { showTerritories.toggle() }
            } label: {
                Image("Territory")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .foregroundStyle(showTerritories ? Color.accentColor : .secondary)
                    .frame(width: 40, height: 40)
                    .glassEffect(in: Circle())
            }
            .accessibilityLabel(showTerritories ? "Hide territories" : "Show territories")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var emptyDescription: String {
        if allEmpty {
            return "Tell the notebook about a visit, or tap + to start a territory."
        }
        if !search.isEmpty {
            return "Try a different search term."
        }
        if !showTerritories {
            return "Territories are hidden — tap the map button to show them."
        }
        return "Nothing to show."
    }

    // MARK: Location + delete

    /// Read the device's location once (best-effort) for distance labels + the Nearest sort.
    private func refreshLocation() async {
        userLocation = await locator.current()
    }

    private func deleteFromList(_ person: Person) {
        ReminderScheduler.shared.cancel(id: person.id)
        context.delete(person)
        context.saveIfPossible()
    }

    private func deleteTerritoryFromList(_ territory: Territory) {
        context.delete(territory)
        context.saveIfPossible()
    }
}
