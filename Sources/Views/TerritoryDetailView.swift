import SwiftUI
import SwiftData
import CoreLocation
import MapKit
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// One territory's working screen:
/// - info (Directions, optional link, optional map image, Share);
/// - the do-not-call list (often scanned from the card);
/// - the not-at-home list you build as you walk — tap a door when someone answers to promote it
///   to a return visit, swipe to re-try (or undo), and each door suggests a better time to return;
/// - a "Suggested nearby" section and a type-to-add field that live-searches addresses around you.
/// Pushed inside the people panel's navigation stack, so it has no stack of its own.
struct TerritoryDetailView: View {
    @Bindable var territory: Territory
    @Environment(\.modelContext) private var context
    @Query private var allTerritories: [Territory]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @StateObject private var location = CurrentLocationProvider()
    @State private var addedCount = 0
    @State private var notice: String?
    @State private var showRename = false
    @State private var draftName = ""
    @State private var showDeleteConfirm = false
    @State private var showCSVExporter = false

    // Due date + KML import
    @State private var showDueDatePicker = false
    @State private var showKMLImporter = false

    // Link + image attachments
    @State private var showLinkEditor = false
    @State private var draftURL = ""
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showImageViewer = false

    // Answered → promote flow
    @State private var answeredDoor: NotAtHome?
    // PROTOTYPE: view/add not-at-homes on a map instead of the list.
    @State private var showDoorsMap = false

    // Add-by-typing + nearby suggestions
    @State private var search = TerritoryAddressSearch()

    var body: some View {
        List {
            infoSection
            dueDateSection
            TerritoryDoorsSection(territory: territory) { answeredDoor = $0 }
            suggestionsSection
        }
        .navigationTitle(territory.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showDoorsMap = true } label: { Image(systemName: "map") }
                    .accessibilityLabel("Not-at-homes on map")
            }
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: shareText) { Image(systemName: "square.and.arrow.up") }
            }
            ToolbarItem(placement: .topBarTrailing) { overflowMenu }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .overlay(alignment: .bottom) { noticeToast }
        .sheet(item: $answeredDoor) { door in
            AnsweredSheet(door: door) { confirmation in
                addedCount += 1
                withAnimation { notice = confirmation }
            }
        }
        .fullScreenCover(isPresented: $showDoorsMap) {
            TerritoryDoorsMap(territory: territory) { answeredDoor = $0 }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .fullScreenCover(isPresented: $showCamera) {
            ImagePicker(sourceType: .camera) { image in
                territory.mapImageData = image.jpegData(compressionQuality: 0.8)
                context.saveIfPossible()
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showImageViewer) { imageViewer }
        .sheet(isPresented: $showCSVExporter) {
            CSVShareSheet(data: NotAtHomeExporter.csv(territory: territory),
                          fileName: "\(territory.name).csv")
        }
        .alert("Rename territory", isPresented: $showRename) {
            TextField("Name", text: $draftName)
            Button("Save") {
                let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { territory.name = trimmed; context.saveIfPossible() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(territory.url == nil ? "Add link" : "Edit link", isPresented: $showLinkEditor) {
            TextField("https://…", text: $draftURL)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            Button("Save") { saveLink() }
            if territory.url != nil {
                Button("Remove", role: .destructive) {
                    territory.urlString = nil; context.saveIfPossible()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \(territory.name)?", isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteTerritory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This territory and all its addresses will be permanently removed.")
        }
        .fileImporter(isPresented: $showKMLImporter,
                      allowedContentTypes: [.kml, .kmz]) { result in
            Task { await importKML(result) }
        }
        .sensoryFeedback(.success, trigger: addedCount)
        .onChange(of: notice) { _, value in
            guard value != nil else { return }
            Task { try? await Task.sleep(for: .seconds(2.2)); withAnimation { notice = nil } }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    territory.mapImageData = data
                    context.saveIfPossible()
                }
                photoItem = nil
            }
        }
        .onChange(of: search.typed) { _, value in search.runLiveSearch(value, territory: territory) }
        .task { await search.loadOnAppear(territory: territory, location: location) }
    }

    // MARK: Sections

    @ViewBuilder
    private var infoSection: some View {
        if territory.coordinate != nil || territory.url != nil || territory.mapImageData != nil {
            Section {
                if territory.coordinate != nil {
                    Button { openDirections() } label: {
                        Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    }
                }
                if let url = territory.url {
                    Button { openURL(url) } label: {
                        Label {
                            Text(url.host ?? url.absoluteString).lineLimit(1)
                        } icon: {
                            Image(systemName: "link")
                        }
                    }
                }
                if let data = territory.mapImageData, let ui = UIImage(data: data) {
                    Button { showImageViewer = true } label: {
                        Image(uiImage: ui)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 170)
                            .frame(maxWidth: .infinity)
                            .clipped()
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets())
                }
            }
        }
    }

    private var dueDateSection: some View {
        Section {
            HStack {
                Label("Due date", systemImage: "calendar.badge.clock")
                Spacer()
                if let due = territory.dueDate {
                    Text(dueLabel(due))
                        .foregroundStyle(territory.isDue() ? .red : .secondary)
                } else {
                    Text("Not set").foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { showDueDatePicker = true }
            .popover(isPresented: $showDueDatePicker) {
                duePopover
            }
        } footer: {
            Text("Set a date to turn in or rotate this territory. You'll get a reminder.")
        }
    }

    private var duePopover: some View {
        VStack(spacing: 12) {
            DatePicker("Due date", selection: Binding(
                get: { territory.dueDate ?? .now },
                set: { territory.dueDate = $0 }
            ), displayedComponents: [.date])
            .datePickerStyle(.graphical)
            .labelsHidden()
            .padding()

            HStack(spacing: 12) {
                Button("Clear") {
                    let id = territory.id
                    territory.dueDate = nil
                    context.saveIfPossible()
                    ReminderScheduler.shared.cancelTerritoryDue(id: id)
                    showDueDatePicker = false
                }
                .buttonStyle(.bordered)

                Button("Save") {
                    if territory.dueDate == nil { territory.dueDate = .now }
                    context.saveIfPossible()
                    if let due = territory.dueDate {
                        ReminderScheduler.shared.scheduleTerritoryDue(
                            id: territory.id, territoryName: territory.name, on: due)
                    }
                    showDueDatePicker = false
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.bottom)
        }
        .presentationCompactAdaptation(.popover)
    }

    private func dueLabel(_ date: Date) -> String {
        let formatted = date.formatted(.dateTime.month(.abbreviated).day().year())
        guard let days = territory.daysUntilDue() else { return formatted }
        switch days {
        case 0:        return "Today"
        case ..<0:     return "Overdue · \(formatted)"
        default:       return formatted
        }
    }

    @ViewBuilder
    private var suggestionsSection: some View {
        let fresh = search.freshAmbient(territory)
        if search.typed.isEmpty, !fresh.isEmpty {
            Section("Suggested nearby") {
                ForEach(fresh) { suggestion in
                    suggestionRow(suggestion)
                }
            }
        }
    }

    private func suggestionRow(_ suggestion: NearbyAddresses.Suggestion) -> some View {
        Button {
            addSuggestion(suggestion)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.address).foregroundStyle(.primary)
                    if let d = search.distanceString(to: suggestion) {
                        Text(d).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Toolbar / bottom bar / overlays

    private var overflowMenu: some View {
        Menu {
            Button {
                draftName = territory.name; showRename = true
            } label: { Label("Rename", systemImage: "pencil") }

            Button {
                draftURL = territory.urlString ?? ""; showLinkEditor = true
            } label: { Label(territory.url == nil ? "Add link" : "Edit link", systemImage: "link") }

            Button { showCamera = true } label: { Label("Take photo", systemImage: "camera") }
            Button { showPhotoPicker = true } label: {
                Label(territory.mapImageData == nil ? "Add image" : "Replace image", systemImage: "photo")
            }
            if territory.mapImageData != nil {
                Button(role: .destructive) {
                    territory.mapImageData = nil; context.saveIfPossible()
                } label: { Label("Remove image", systemImage: "photo.badge.minus") }
            }

            Button { showKMLImporter = true } label: {
                Label("Import boundary (KML/KMZ)", systemImage: "arrow.down.doc")
            }

            Button { showCSVExporter = true } label: {
                Label("Export as CSV", systemImage: "tablecells")
            }

            Divider()

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: { Label("Delete territory", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            // Type-to-add field on top, so it stays visible above the keyboard while you type.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Type an address to add…", text: $search.typed)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                if !search.typed.isEmpty {
                    Button { search.typed = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .glassEffect(in: Capsule())

            // Live matches for what you're typing — right below the field.
            if !search.typed.isEmpty {
                VStack(spacing: 0) {
                    if search.liveResults.isEmpty {
                        Text(search.searching ? "Searching nearby…" : "No matches nearby")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(search.liveResults.prefix(4)) { suggestion in
                            Button { addSuggestion(suggestion) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
                                    Text(suggestion.address).lineLimit(1).foregroundStyle(.primary)
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 7)
                            }
                            .buttonStyle(.plain)
                            if suggestion.id != search.liveResults.prefix(4).last?.id { Divider() }
                        }
                    }
                }
            }

            Button {
                Task {
                    await search.addNearest(territory: territory, context: context, location: location,
                                            notify: { showNotice($0) },
                                            confirm: { confirmAdd($0) })
                }
            } label: {
                HStack(spacing: 8) {
                    if search.isAdding { ProgressView().tint(.white) } else { Image(systemName: "location.fill") }
                    Text(search.isAdding ? "Finding address…" : "Add nearest address")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(search.isAdding)
        }
        .padding()
        .background(.bar)
    }

    @ViewBuilder
    private var noticeToast: some View {
        if let notice {
            Text(notice)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 150)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var imageViewer: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let data = territory.mapImageData, let ui = UIImage(data: data) {
                Image(uiImage: ui).resizable().scaledToFit()
            }
            VStack {
                HStack {
                    Spacer()
                    Button { showImageViewer = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.9))
                            .padding()
                    }
                }
                Spacer()
            }
        }
    }

    /// A plain-text summary for the share sheet: the territory, its do-not-calls, and not-at-homes.
    private var shareText: String {
        NotAtHomeExporter.plainText(territory: territory)
    }

    // MARK: Actions

    /// Add a suggestion as a door (used by both the live-results list and the "Suggested nearby"
    /// section); confirmation toast handled via `confirmAdd`.
    private func addSuggestion(_ suggestion: NearbyAddresses.Suggestion) {
        search.addSuggestion(suggestion, territory: territory, context: context) { confirmAdd($0) }
    }

    /// A successful add: bump the success-feedback counter and show a confirmation toast.
    private func confirmAdd(_ message: String) {
        addedCount += 1
        withAnimation { notice = message }
    }

    /// A non-success message (e.g. location off): show a toast without the success feedback.
    private func showNotice(_ message: String) {
        withAnimation { notice = message }
    }

    private func openDirections() {
        guard let c = territory.coordinate else { return }
        let item = MKMapItem(location: CLLocation(latitude: c.latitude, longitude: c.longitude),
                             address: nil)
        item.name = territory.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }

    private func saveLink() {
        var s = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { territory.urlString = nil; context.saveIfPossible(); return }
        if !s.contains("://") { s = "https://" + s }
        territory.urlString = s
        context.saveIfPossible()
    }

    /// Import KML/KMZ polygons and match them to territories by Placemark name (creating any
    /// that don't exist). The boundary for *this* territory is applied when a name matches it.
    private func importKML(_ result: Result<URL, Error>) async {
        guard let fileURL = try? result.get() else { return }
        let needsStop = fileURL.startAccessingSecurityScopedResource()
        defer { if needsStop { fileURL.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: fileURL)
            let placemarks = try await Task.detached { try KMLParser.parse(data: data) }.value
            guard !placemarks.isEmpty else {
                withAnimation { notice = "No polygons found in that file." }
                return
            }
            var imported = 0
            for placemark in placemarks {
                let target = allTerritories.first { $0.name == placemark.name }
                if let target {
                    target.setBoundary(placemark.coordinates)
                } else {
                    let created = Territory(name: placemark.name.isEmpty ? "Imported territory" : placemark.name)
                    created.setBoundary(placemark.coordinates)
                    context.insert(created)
                }
                imported += 1
            }
            context.saveIfPossible()
            withAnimation {
                notice = imported == 1 ? "Imported 1 boundary." : "Imported \(imported) boundaries."
            }
        } catch {
            withAnimation { notice = "Import failed: \(error.localizedDescription)" }
        }
    }

    private func deleteTerritory() {
        context.delete(territory)
        context.saveIfPossible()
        dismiss()
    }
}

/// Shown when someone finally answers a not-at-home. Captures who/what, then either promotes the
/// door to a return visit (the promising path) or records a note / removes the door.
private struct AnsweredSheet: View {
    @Bindable var door: NotAtHome
    var onFinish: (String) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var note = ""
    @State private var interest: InterestLevel = .interested   // "None" by default → not-promising
    @State private var confirmDropDoor = false

    private var promising: Bool { interest.isPromising }
    private var trimmedNote: String { note.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(door.address).font(.subheadline).foregroundStyle(.secondary)
                } footer: {
                    Text(door.attemptCount <= 1
                         ? "Logged once."
                         : "Tried \(door.attemptCount)× since "
                           + door.createdAt.formatted(.dateTime.month(.abbreviated).day()) + ".")
                }
                Section("Who answered") {
                    TextField("Name (optional)", text: $name).textContentType(.name)
                }
                Section("What happened") {
                    TextField("e.g. liked the tract, asked about suffering", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                }
                Section("Interest") {
                    Picker("Interest", selection: $interest) {
                        ForEach(InterestLevel.allCases) { level in
                            Label(level.label, systemImage: level.symbol).tag(level)
                        }
                    }
                    .pickerStyle(.menu)
                    if promising {
                        Label("Worth a return visit", systemImage: "sparkles")
                            .font(.caption).foregroundStyle(.green).transition(.opacity)
                    }
                }
            }
            .animation(.default, value: promising)
            .navigationTitle("Someone answered")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) { actionBar }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .confirmationDialog("Remove this door?", isPresented: $confirmDropDoor, titleVisibility: .visible) {
            Button("Remove door", role: .destructive) { removeDoor() }
            Button("Keep on list", role: .cancel) {}
        } message: {
            Text("Someone answered, so it's no longer a not-at-home. Remove it from the territory?")
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        VStack(spacing: 10) {
            Button { promote() } label: {
                Label("Save as return visit", systemImage: "person.crop.circle.badge.plus")
                    .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(promising ? .accentColor : .secondary)

            HStack {
                Button("Just add a note") { addNoteOnly() }
                    .buttonStyle(.bordered)
                    .disabled(trimmedNote.isEmpty && name.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Button("Remove door", role: .destructive) { confirmDropDoor = true }
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .font(.subheadline)
        }
        .padding()
        .background(.bar)
    }

    private func promote() {
        let territory = door.territory
        let person = NotAtHomePromotion.promote(door, name: name, note: note,
                                                interest: interest, in: context)
        context.delete(door)
        territory?.touch()
        context.saveIfPossible()
        dismiss()
        onFinish("Saved \(person.name.isEmpty ? "return visit" : person.name).")
    }

    private func addNoteOnly() {
        let stamp = Date.now.formatted(.dateTime.month().day())
        let line = [name.trimmingCharacters(in: .whitespaces), trimmedNote]
            .filter { !$0.isEmpty }.joined(separator: " — ")
        if !line.isEmpty {
            door.note = door.note.isEmpty ? "\(stamp): \(line)" : door.note + "\n\(stamp): \(line)"
        }
        door.markTriedAgain()
        door.territory?.touch()
        context.saveIfPossible()
        dismiss()
        onFinish("Note added to \(door.address).")
    }

    private func removeDoor() {
        let address = door.address
        let territory = door.territory
        context.delete(door)
        territory?.touch()
        context.saveIfPossible()
        dismiss()
        onFinish("Removed \(address).")
    }
}

#if DEBUG
#Preview("Territory detail") {
    NavigationStack {
        TerritoryDetailView(territory: PreviewData.territory)
    }
    .modelContainer(PreviewData.container)
}

#Preview("Answered sheet") {
    Text("Backing view")
        .sheet(isPresented: .constant(true)) {
            AnsweredSheet(door: PreviewData.door) { _ in }
        }
        .modelContainer(PreviewData.container)
}
#endif
