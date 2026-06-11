import SwiftUI
import SwiftData
import MapKit
import CoreLocation
import UIKit

/// How the People feed is ordered.
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

/// The People tab: a tappable map preview up top, then your people (image-forward masonry) and your
/// territories (their own section) below. Search is native; sort and backup live in the toolbar.
/// Tapping a card — or a pin in the expanded map — opens the matching detail screen.
struct PeoplePanelContent: View {
    @Query(filter: #Predicate<Person> { !$0.isArchived },
           sort: \Person.createdAt, order: .reverse) private var people: [Person]
    @Query(sort: \Territory.createdAt, order: .reverse) private var territories: [Territory]
    @State private var selected: MapTarget?

    @Environment(\.modelContext) private var context
    @StateObject private var locator = CurrentLocationProvider()
    @State private var search = ""
    @State private var sort: SortMode = .recent
    @State private var userLocation: CLLocation?
    @State private var addingTerritory = false
    @State private var personToDelete: Person?
    @State private var territoryToDelete: Territory?
    @State private var showingScan = false
    @State private var showNotebook = false
    @State private var showNewPerson = false
    @State private var showBackup = false
    @State private var detectedDuplicates: Set<DuplicatePair> = []
    @State private var mergeSource: Person?
    @State private var mergeTarget: Person?
    @State private var mergeResult: String?
    @Namespace private var mapZoom

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
        territories.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var sortedPeople: [Person] {
        switch sort {
        case .recent:  return filteredPeople.sorted { $0.createdAt > $1.createdAt }
        case .nearest: return sortedByDistance(filteredPeople) { $0.coordinate }
        case .due:     return filteredPeople.sorted { ($0.nextVisitDate ?? .distantFuture) < ($1.nextVisitDate ?? .distantFuture) }
        case .name:    return filteredPeople.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private var sortedTerritories: [Territory] {
        switch sort {
        case .recent, .due: return filteredTerritories.sorted { $0.createdAt > $1.createdAt }
        case .nearest:      return sortedByDistance(filteredTerritories) { $0.coordinate }
        case .name:         return filteredTerritories.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private func sortedByDistance<T>(_ items: [T], _ coordinate: (T) -> CLLocationCoordinate2D?) -> [T] {
        guard let userLocation else { return items }
        func distance(_ item: T) -> CLLocationDistance {
            guard let c = coordinate(item) else { return .greatestFiniteMagnitude }
            return CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: userLocation)
        }
        return items.sorted { distance($0) < distance($1) }
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
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if addingTerritory {
                        AddTerritoryInline(
                            onCreated: { territory in
                                addingTerritory = false
                                selected = .territory(territory)
                            },
                            onCancel: { addingTerritory = false }
                        )
                    }

                    if sortedPeople.isEmpty && sortedTerritories.isEmpty && !addingTerritory {
                        emptyState
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else {
                        if !sortedPeople.isEmpty {
                            sectionHeader("People")
                            peopleMasonry
                        }
                        if !sortedTerritories.isEmpty {
                            sectionHeader("Territories")
                            territoryList
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.immediately)
            // iOS 27: opt this scroll layout into swipe actions so the cards' .swipeActions work
            // outside a List.
            .swipeActionsContainer()
            .navigationTitle("People")
            .searchable(text: $search, prompt: "Search people & territories")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showBackup = true } label: { Image(systemName: "icloud.and.arrow.down") }
                        .accessibilityLabel("Backup & Restore")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort by", selection: $sort) {
                            ForEach(SortMode.allCases) { mode in
                                Label(mode.label, systemImage: mode.symbol).tag(mode)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .accessibilityLabel("Sort")
                }
            }
            .safeAreaInset(edge: .bottom) { notebookComposer }
            .navigationDestination(item: $selected) { target in
                switch target {
                case .person(let person):
                    PersonDetailView(person: person)
                        .navigationTransition(.zoom(sourceID: "person-\(person.id)", in: mapZoom))
                case .territory(let territory):
                    TerritoryDetailView(territory: territory)
                        .navigationTransition(.zoom(sourceID: "territory-\(territory.id)", in: mapZoom))
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
            .sheet(isPresented: $showNewPerson) {
                NewPersonView { person in selected = .person(person) }
            }
            .sheet(isPresented: $showBackup) {
                SettingsView()
            }
            .alert(
                "Delete \(personToDelete?.name ?? "")?",
                isPresented: Binding(get: { personToDelete != nil },
                                     set: { if !$0 { personToDelete = nil } })
            ) {
                Button("Delete", role: .destructive) {
                    if let p = personToDelete { deleteFromList(p) }
                    personToDelete = nil
                }
                Button("Cancel", role: .cancel) { personToDelete = nil }
            } message: {
                Text("All notes and visit history will be permanently removed.")
            }
            .alert(
                "Delete \(territoryToDelete?.name ?? "")?",
                isPresented: Binding(get: { territoryToDelete != nil },
                                     set: { if !$0 { territoryToDelete = nil } })
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
            .onAppear { detectedDuplicates = DuplicateDetector.findDuplicates(in: people) }
            .onChange(of: people) { _, newPeople in
                detectedDuplicates = DuplicateDetector.findDuplicates(in: newPeople)
            }
            .confirmationDialog(
                "Merge \(mergeSource?.name ?? "") into \(mergeTarget?.name ?? "")?",
                isPresented: Binding(get: { mergeSource != nil && mergeTarget != nil },
                                     set: { if !$0 { mergeSource = nil; mergeTarget = nil } }),
                titleVisibility: .visible
            ) {
                Button("Merge", role: .destructive) {
                    if let source = mergeSource, let target = mergeTarget {
                        mergeResult = NotebookEngine.merge(source: source, into: target, context: context)
                    }
                    mergeSource = nil; mergeTarget = nil
                }
                Button("Cancel", role: .cancel) { mergeSource = nil; mergeTarget = nil }
            } message: {
                if let source = mergeSource, let target = mergeTarget {
                    Text("All notes from \(source.name) move to \(target.name), and \(source.name) is deleted.")
                }
            }
            .alert("Merged", isPresented: Binding(get: { mergeResult != nil },
                                                  set: { if !$0 { mergeResult = nil } })) {
                Button("OK", role: .cancel) { mergeResult = nil }
            } message: {
                Text(mergeResult ?? "")
            }
        }
    }

    // MARK: Map preview

    // MARK: Sections

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.bold))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Two-column, image-forward masonry of people.
    private var peopleMasonry: some View {
        let columns = balanceIntoColumns(sortedPeople, height: estimatedHeight)
        return HStack(alignment: .top, spacing: 12) {
            peopleColumn(columns.left)
            peopleColumn(columns.right)
        }
    }

    private func peopleColumn(_ items: [Person]) -> some View {
        LazyVStack(spacing: 12) {
            ForEach(items) { personCard($0) }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func personCard(_ person: Person) -> some View {
        Button { selected = .person(person) } label: {
            PersonGridCard(person: person,
                           heroHeight: heroHeight(for: person))
        }
        .buttonStyle(.plain)
        .matchedTransitionSource(id: "person-\(person.id)", in: mapZoom)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { personToDelete = person } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            let others = duplicatePartners(of: person)
            if !others.isEmpty {
                Menu {
                    ForEach(others) { other in
                        Button {
                            mergeSource = other
                            mergeTarget = person
                        } label: {
                            Label("Merge with \(other.name)", systemImage: "person.2")
                        }
                    }
                } label: {
                    Label("Merge", systemImage: "person.2.fill")
                }
            }
            Button(role: .destructive) { personToDelete = person } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// The active people flagged as likely duplicates of `person`, by the detected pairs.
    private func duplicatePartners(of person: Person) -> [Person] {
        let partnerIDs = detectedDuplicates.compactMap { pair -> UUID? in
            if pair.id1 == person.id { return pair.id2 }
            if pair.id2 == person.id { return pair.id1 }
            return nil
        }
        return partnerIDs.compactMap { id in people.first { $0.id == id } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Territories as their own single-column section.
    private var territoryList: some View {
        LazyVStack(spacing: 12) {
            ForEach(sortedTerritories) { territory in
                Button { selected = .territory(territory) } label: {
                    TerritoryGridCard(territory: territory,
                                      distanceText: distanceText(for: territory.coordinate))
                }
                .buttonStyle(.plain)
                .matchedTransitionSource(id: "territory-\(territory.id)", in: mapZoom)
                .contextMenu {
                    Button(role: .destructive) { territoryToDelete = territory } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    /// A rough card height, used only to balance the two people columns (never for actual layout).
    private func estimatedHeight(_ person: Person) -> CGFloat {
        if person.coordinate != nil { return heroHeight(for: person) }
        var h: CGFloat = 70
        if !person.headline.isEmpty {
            h += min((CGFloat(person.headline.count) / 22).rounded(.up), 5) * 18
        }
        if person.nextVisitDate != nil { h += 18 }
        return h
    }

    /// Deterministic hero height per person so the stagger stays stable across launches.
    private func heroHeight(for person: Person) -> CGFloat {
        let options: [CGFloat] = [200, 250, 300]
        return options[Int(person.id.uuid.0) % 3]
    }

    private var emptyState: some View {
        ContentUnavailableView(
            allEmpty ? "Nothing yet" : "No matches",
            systemImage: allEmpty ? "person.2" : "magnifyingglass",
            description: Text(emptyDescription)
        )
    }

    private var emptyDescription: String {
        if allEmpty {
            return "Tell the notebook about a visit, or tap + to start a territory."
        }
        if !search.isEmpty {
            return "Try a different search term."
        }
        return "Nothing to show."
    }

    // MARK: Add (bottom composer)

    /// Bottom composer: a leading add-menu, then a tap-to-chat field that opens the notebook
    /// scratchpad with the keyboard up. "New person" lands in that same scratchpad.
    private var notebookComposer: some View {
        HStack(spacing: 10) {
            Menu {
                Button { showNewPerson = true } label: { Label("New person", systemImage: "person.badge.plus") }
                Button { withAnimation { addingTerritory = true } } label: { Label("New territory", systemImage: "map") }
                Button { showingScan = true } label: { Label("Scan territory card", systemImage: "doc.text.viewfinder") }
            } label: {
                Image(systemName: "plus")
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

#if DEBUG
#Preview("People panel") {
    PeoplePanelContent()
        .modelContainer(PreviewData.container)
}
#endif
