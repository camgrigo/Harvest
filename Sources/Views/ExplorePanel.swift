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
                    feedList
                }
            }
            // Inline search + sort + territory toggle, pinned above the list.
            .safeAreaInset(edge: .top, spacing: 0) { controlBar }
            // Tap-to-chat with the notebook, pinned to the bottom of the panel.
            .safeAreaInset(edge: .bottom) { notebookComposer }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
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
