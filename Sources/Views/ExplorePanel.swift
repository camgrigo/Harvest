import SwiftUI
import SwiftData
import MapKit
import CoreLocation
import UIKit

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

/// The unified feed shown inside the panel: people (return visits) and territories
/// (house-to-house areas). Tapping a row — or a map pin — sets `selected`, which both focuses
/// the map and pushes the matching detail screen within this stack.
struct PeoplePanelContent: View {
    let people: [Person]
    let territories: [Territory]
    @Binding var selected: MapTarget?
    /// The panel reports its live height here so the map's locate button can float just above it.
    @Binding var sheetHeight: CGFloat

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
    @State private var showSettings = false
    @State private var showPlans = false

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
                    masonryFeed
                }
            }
            // Inline search + sort + territory toggle, pinned above the feed.
            .safeAreaInset(edge: .top, spacing: 0) { controlBar }
            // Tap-to-chat with the notebook, pinned to the bottom of the panel.
            .safeAreaInset(edge: .bottom) { notebookComposer }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape.fill") }
                        .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showPlans = true } label: { Image(systemName: "calendar") }
                        .accessibilityLabel("Service plans")
                }
            }
            .navigationDestination(item: $selected) { target in
                switch target {
                case .person(let person):
                    PersonDetailView(person: person)
                case .territory(let territory):
                    TerritoryDetailView(territory: territory)
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
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showPlans) { ServicePlansView() }
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
        // Tell the map how tall the sheet is right now (tracks interactive drags too).
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sheetHeight = $0 }
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
                    .foregroundStyle(.white, Color.accentColor)
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

    // MARK: Feed (masonry)

    /// Two-column, image-forward masonry. Items are packed greedily into whichever column is
    /// currently shorter (by estimated height), giving the staggered look without measuring.
    private var masonryFeed: some View {
        ScrollView {
            VStack(spacing: 12) {
                if addingTerritory {
                    AddTerritoryInline(
                        onCreated: { territory in
                            addingTerritory = false
                            selected = .territory(territory)
                        },
                        onCancel: { addingTerritory = false }
                    )
                }
                let columns = balanceIntoColumns(feed, height: estimatedHeight)
                HStack(alignment: .top, spacing: 12) {
                    masonryColumn(columns.left)
                    masonryColumn(columns.right)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
    }

    private func masonryColumn(_ items: [FeedItem]) -> some View {
        LazyVStack(spacing: 12) {
            ForEach(items) { gridCard(for: $0) }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func gridCard(for item: FeedItem) -> some View {
        switch item {
        case .person(let person):
            Button {
                selected = .person(person)
            } label: {
                PersonGridCard(person: person,
                               distanceText: distanceText(for: person.coordinate),
                               heroHeight: heroHeight(for: person))
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button(role: .destructive) { personToDelete = person } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        case .territory(let territory):
            Button {
                selected = .territory(territory)
            } label: {
                TerritoryGridCard(territory: territory,
                                  distanceText: distanceText(for: territory.coordinate))
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button(role: .destructive) { territoryToDelete = territory } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    /// A rough card height, used only to balance the two columns (never for actual layout).
    private func estimatedHeight(_ item: FeedItem) -> CGFloat {
        switch item {
        case .person(let p):
            // Photo cards: the image fills the card, so height ≈ the hero height.
            if p.coordinate != nil { return heroHeight(for: p) }
            // Text-only cards: name + headline + due.
            var h: CGFloat = 70
            if !p.headline.isEmpty {
                h += min((CGFloat(p.headline.count) / 22).rounded(.up), 5) * 18
            }
            if p.nextVisitDate != nil { h += 18 }
            return h
        case .territory:
            return 120                               // compact text tile
        }
    }

    /// Deterministic hero height per person so the stagger stays stable across launches.
    private func heroHeight(for person: Person) -> CGFloat {
        let options: [CGFloat] = [120, 146, 172]
        return options[Int(person.id.uuid.0) % 3]
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

/// Greedy two-column packing for the masonry feed: each item is appended to whichever column is
/// currently shorter by accumulated height. Order within each column is preserved. Pure and
/// generic so it can be unit-tested without a view.
func balanceIntoColumns<T>(_ items: [T], height: (T) -> CGFloat) -> (left: [T], right: [T]) {
    var left: [T] = [], right: [T] = []
    var leftHeight: CGFloat = 0, rightHeight: CGFloat = 0
    for item in items {
        if leftHeight <= rightHeight {
            left.append(item); leftHeight += height(item)
        } else {
            right.append(item); rightHeight += height(item)
        }
    }
    return (left, right)
}
