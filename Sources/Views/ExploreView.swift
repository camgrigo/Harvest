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

/// Map and people combined into one screen (Find My style): a full-bleed territory map with a
/// native bottom sheet of people that floats above it (background interaction stays enabled so
/// the map is still pannable). Tapping a pin opens that person in the sheet; touch and hold the
/// map to drop a new pin.
struct ExploreView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Person> { !$0.isArchived },
           sort: \Person.createdAt, order: .reverse) private var people: [Person]

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selection: Person?
    @State private var dropped: DroppedPin?
    @State private var locationManager = CLLocationManager()
    @State private var detent: PresentationDetent = .medium
    @State private var isPitched = false
    @StateObject private var locator = CurrentLocationProvider()
    @State private var didSetDefaultCamera = false

    /// The default map view never zooms out past this radius around you.
    private static let maxDefaultRadius: CLLocationDistance = 30 * 1609.34   // 30 miles

    /// Resting "peek" height that keeps the search field and a couple of rows visible.
    private static let peek: PresentationDetent = .height(120)

    /// Default detent when a person is selected — tall enough to show all their info without
    /// going full-screen, so the map pin stays visible above the sheet.
    private static let selected: PresentationDetent = .fraction(0.7)

    private var located: [Person] { people.filter { $0.coordinate != nil } }

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
            .onChange(of: selection) { _, newValue in
                guard let person = newValue else { return }
                if let coordinate = person.coordinate {
                    // Focus the map on the tapped person's pin...
                    withAnimation(.easeInOut) {
                        camera = .region(MKCoordinateRegion(
                            center: coordinate,
                            latitudinalMeters: 400, longitudinalMeters: 400))
                    }
                    // ...and rest the sheet at 70 % so the pin stays visible above it.
                    detent = Self.selected
                } else {
                    // No pin to focus — show the person's page in full.
                    detent = .large
                }
            }
            .sheet(isPresented: .constant(true)) {
                PeoplePanelContent(people: people, selection: $selection)
                    .presentationDetents([Self.peek, .medium, Self.selected, .large], selection: $detent)
                    .presentationBackgroundInteraction(.enabled(upThrough: Self.selected))
                    .presentationContentInteraction(.scrolls)
                    .presentationBackground(.regularMaterial)
                    .interactiveDismissDisabled()
                    .sheet(item: $dropped) { pin in
                        LocationActionView(coordinate: pin.coordinate)
                    }
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
            Map(position: $camera, selection: $selection) {
                UserAnnotation()
                ForEach(located) { person in
                    Marker(person.name,
                           systemImage: person.interest.symbol,
                           coordinate: person.coordinate!)
                        .tint(person.isDue ? .red : .blue)
                        .tag(person)
                }
                if let dropped {
                    Marker("New pin", systemImage: "mappin", coordinate: dropped.coordinate)
                        .tint(.green)
                }
            }
            // Disable all built-in controls — we render our own overlay below.
            .mapControls { }
            .gesture(dropPinGesture(proxy))
            // Tiles bleed full-screen under the status bar.
            .ignoresSafeArea(.container, edges: .top)
            // Keep the bottom clear of the resting sheet.
            .safeAreaPadding(.bottom, 120)
            // Custom nav buttons in an overlay that genuinely respects the safe area.
            .overlay(alignment: .topTrailing) {
                mapControls
                    .padding(.top)            // one unit below the safe-area top edge
                    .padding(.trailing, 8)
                    .padding(.top, 4)         // tiny extra breathing room from the status bar
            }
        }
    }

    /// User-location, 2D/3D pitch, and a compass — styled to match MapKit's native buttons.
    private var mapControls: some View {
        VStack(spacing: 8) {
            // Re-centre on the user.
            Button {
                withAnimation { camera = .userLocation(fallback: .automatic) }
            } label: {
                Image(systemName: "location.fill")
                    .mapControlStyle()
            }
            .accessibilityLabel("My location")

            // 2D / 3D pitch toggle.
            Button {
                isPitched.toggle()
                withAnimation {
                    if isPitched {
                        camera = .camera(MapCamera(
                            centerCoordinate: currentCenter,
                            distance: 1500, heading: 0, pitch: 60))
                    } else {
                        camera = .camera(MapCamera(
                            centerCoordinate: currentCenter,
                            distance: 1500, heading: 0, pitch: 0))
                    }
                }
            } label: {
                Text(isPitched ? "2D" : "3D")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .mapControlStyle()
            }
            .accessibilityLabel(isPitched ? "Switch to 2D" : "Switch to 3D")
        }
    }

    /// Best-effort current map center — prefers the camera's own coordinate, falls back to
    /// the first located person, then a hard-coded coordinate.
    private var currentCenter: CLLocationCoordinate2D {
        if let c = camera.camera { return c.centerCoordinate }
        if let r = camera.region { return r.center }
        if let first = located.first?.coordinate { return first }
        return CLLocationCoordinate2D(latitude: 0, longitude: 0)
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

/// The people list shown inside the panel. Tapping a row (or a map pin) drives the same
/// `selection`, which pushes the person's page within this stack.
private struct PeoplePanelContent: View {
    let people: [Person]
    @Binding var selection: Person?

    @Environment(\.modelContext) private var context
    @StateObject private var locator = CurrentLocationProvider()
    @State private var search = ""
    @State private var onlyDue = false
    @State private var nearMe = true
    @State private var userLocation: CLLocation?
    @State private var locating = false
    @State private var showingAdd = false
    @State private var showingFilters = false
    @State private var personToDelete: Person?

    private var filtered: [Person] {
        let base = people.filter { person in
            (!onlyDue || person.isDue)
            // "Near me" only makes sense for people we can place on the map.
            && (!nearMe || person.coordinate != nil)
            && (search.isEmpty
                || person.name.localizedCaseInsensitiveContains(search)
                || person.headline.localizedCaseInsensitiveContains(search))
        }
        guard nearMe, let userLocation else { return base }
        return base.sorted { distance($0, from: userLocation) < distance($1, from: userLocation) }
    }

    /// Straight-line distance from the user to a person's pin (huge value if unplaced, so they sink).
    private func distance(_ person: Person, from origin: CLLocation) -> CLLocationDistance {
        guard let c = person.coordinate else { return .greatestFiniteMagnitude }
        return CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: origin)
    }

    /// Abbreviated, locale-aware distance ("0.3 mi") shown on each row in Near-me mode.
    private func distanceText(for person: Person) -> String? {
        guard nearMe, let userLocation, person.coordinate != nil else { return nil }
        return Self.distanceFormatter.string(fromDistance: distance(person, from: userLocation))
    }

    private static let distanceFormatter: MKDistanceFormatter = {
        let formatter = MKDistanceFormatter()
        formatter.unitStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        NavigationStack {
            Group {
                if filtered.isEmpty && !showingAdd {
                    ContentUnavailableView(
                        people.isEmpty ? "No one yet" : "No matches",
                        systemImage: people.isEmpty
                            ? "person.crop.circle.badge.questionmark"
                            : "magnifyingglass",
                        description: Text(emptyDescription)
                    )
                    .overlay(alignment: .top) {
                        if showingAdd {
                            AddPersonInline { showingAdd = false }
                                .padding()
                        }
                    }
                } else {
                    List {
                        if showingAdd {
                            AddPersonInline { showingAdd = false }
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        }
                        ForEach(filtered) { person in
                            Button {
                                selection = person
                            } label: {
                                PersonCard(person: person, distanceText: distanceText(for: person))
                            }
                            .buttonStyle(.plain)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    personToDelete = person
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            // Filter options — shown below the search bar when the filter button is active.
            .safeAreaInset(edge: .top, spacing: 0) {
                if showingFilters {
                    filterStrip
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search names or notes")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showingFilters.toggle() }
                    } label: {
                        // Fill the icon whenever the panel is open OR a non-default filter is on.
                        Image(systemName: (showingFilters || onlyDue)
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .accessibilityLabel("Filters")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation { showingAdd.toggle() }
                    } label: {
                        Image(systemName: showingAdd ? "xmark.circle.fill" : "plus")
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
            }
            .navigationDestination(item: $selection) { person in
                PersonDetailView(person: person)
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
            .onChange(of: nearMe) { _, on in
                if on {
                    Task { await refreshLocation() }
                } else {
                    userLocation = nil
                }
            }
            // "Near me" is on by default, so fetch the location once on appear
            // (onChange won't fire for the initial value).
            .task {
                if nearMe, userLocation == nil { await refreshLocation() }
            }
        }
    }

    /// A compact horizontal strip of filter toggles that drops in below the search bar.
    private var filterStrip: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $onlyDue) {
                Label("Due", systemImage: "bell")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .disabled(people.isEmpty)

            Toggle(isOn: $nearMe) {
                Label(
                    locating ? "Locating…" : "Near me",
                    systemImage: locating ? "location.fill" : "location"
                )
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .disabled(people.isEmpty || locating)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var emptyDescription: String {
        if people.isEmpty {
            return "Tell the notebook about a visit, or touch and hold the map to drop a pin."
        }
        if !search.isEmpty {
            return "Try a different search term, or adjust your filters."
        }
        if onlyDue && nearMe {
            return "No one nearby has a visit due. Try turning off a filter."
        }
        if onlyDue {
            return "No visits are due right now."
        }
        if nearMe {
            return "No one with a map pin is nearby. Add an address so they show up here."
        }
        return "Try adjusting your filters."
    }

    /// Read the device's location once; if it can't be obtained, drop back out of Near-me mode.
    private func refreshLocation() async {
        locating = true
        userLocation = await locator.current()
        locating = false
        if userLocation == nil { nearMe = false }
    }

    private func deleteFromList(_ person: Person) {
        ReminderScheduler.shared.cancel(id: person.id)
        context.delete(person)
        context.saveIfPossible()
    }
}

/// A square Look Around still of a person's address, loaded lazily per row.
/// Falls back to a placeholder when Apple has no Look Around coverage for the spot.
///
/// Snapshots are cached (keyed by rounded coordinate) so scrolling a row off and back
/// reuses the still instead of re-fetching and flashing the placeholder. Main-actor
/// isolated, so the cached `UIImage`s never cross an isolation boundary.
@MainActor
private enum LookAroundCache {
    static var images: [String: UIImage] = [:]

    static func key(for coordinate: CLLocationCoordinate2D) -> String {
        // ~1 m precision — plenty to dedupe the same address.
        String(format: "%.5f,%.5f", coordinate.latitude, coordinate.longitude)
    }
}

private struct RowLookAround: View {
    let coordinate: CLLocationCoordinate2D
    var side: CGFloat = 84

    @State private var image: UIImage?
    @State private var didLoad = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                // No image yet (loading) or no coverage — invisible spacer keeps text aligned.
                Color.clear.frame(width: side, height: side)
            }
        }
        .task {
            guard !didLoad else { return }
            let key = LookAroundCache.key(for: coordinate)
            if let cached = LookAroundCache.images[key] {
                image = cached          // cache hit — no fetch, no flicker
                didLoad = true
                return
            }
            if let loaded = await Self.loadImage(at: coordinate) {
                LookAroundCache.images[key] = loaded
                image = loaded
            }
            didLoad = true
        }
    }

    /// Fetches the scene and renders it to a still image off the main actor (both are
    /// non-Sendable); `sending` lets the finished image cross back to the view safely.
    private nonisolated static func loadImage(
        at coordinate: CLLocationCoordinate2D
    ) async -> sending UIImage? {
        guard let scene = try? await MKLookAroundSceneRequest(coordinate: coordinate).scene else {
            return nil
        }
        let options = MKLookAroundSnapshotter.Options()
        options.size = CGSize(width: 400, height: 400)   // square, rendered at @1x points
        options.pointOfInterestFilter = .excludingAll
        guard let snapshot = try? await MKLookAroundSnapshotter(scene: scene, options: options).snapshot else {
            return nil
        }
        return snapshot.image
    }
}

// MARK: - Person card

/// A scannable card for one person: a square Look Around still (with distance badge
/// overlaid), the name prefixed by a small status icon, a headline, and the reminder
/// date at the bottom — all in a single glass card.
private struct PersonCard: View {
    let person: Person
    let distanceText: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                // Name row — small status icon (only when status is set) before the name.
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if person.interest != .interested {
                        Image(systemName: person.interest.symbol)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    Text(person.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("personRow.name")
                    Spacer(minLength: 0)
                }
                if !person.headline.isEmpty {
                    Text(person.headline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                // Reminder date where the status chip used to be.
                if let due = dueText(for: person) {
                    Text(due)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(person.isDue ? .red : .secondary)
                }
            }
            thumbnail
        }
        .padding(12)
        .glassEffect(in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let coordinate = person.coordinate {
            // Look Around still with the distance badge pinned to the bottom-leading corner.
            ZStack(alignment: .bottomTrailing) {
                RowLookAround(coordinate: coordinate)
                if let distanceText {
                    Text(distanceText)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.5),
                                    in: RoundedRectangle(cornerRadius: 5))
                        .padding(5)
                }
            }
        } else {
            // No coordinate — invisible spacer keeps text aligned with thumbnail cells.
            Color.clear.frame(width: 84, height: 84)
        }
    }

    /// A short, scannable due string: "Due today", "Overdue 3d", "Tomorrow", "in 5d",
    /// or an abbreviated date when it's further out. nil when no reminder is set.
    private func dueText(for person: Person) -> String? {
        guard let date = person.nextVisitDate else { return nil }
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: .now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0

        switch days {
        case 0:    return "Due today"
        case ..<0: return days == -1 ? "Overdue 1d" : "Overdue \(-days)d"
        case 1:    return "Tomorrow"
        case 2...14: return "in \(days)d"
        default:   return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}

private extension InterestLevel {
    var tint: Color {
        switch self {
        case .new: .purple
        case .interested: .green
        case .studying: .blue
        case .paused: .gray
        }
    }
}

private struct DuePill: View {
    let text: String
    let overdue: Bool

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(overdue ? .red : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .glassEffect(.regular, in: Capsule())
    }
}

private struct InterestChip: View {
    let interest: InterestLevel

    var body: some View {
        Label(interest.label, systemImage: interest.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(interest.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .glassEffect(.regular, in: Capsule())
    }
}

// MARK: - Map control button style

private extension View {
    /// iOS 26 glass circle — matches the system's native map control look.
    func mapControlStyle() -> some View {
        self
            .frame(width: 42, height: 42)
            .glassEffect(in: Circle())
    }
}
