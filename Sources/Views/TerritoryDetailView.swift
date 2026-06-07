import SwiftUI
import SwiftData
import CoreLocation
import MapKit
import PhotosUI
import UIKit

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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @StateObject private var location = CurrentLocationProvider()
    @State private var isAdding = false
    @State private var addedCount = 0
    @State private var notice: String?
    @State private var showRename = false
    @State private var draftName = ""
    @State private var showDeleteConfirm = false

    // Link + image attachments
    @State private var showLinkEditor = false
    @State private var draftURL = ""
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showImageViewer = false

    // Answered → promote flow
    @State private var answeredDoor: NotAtHome?

    // Add-by-typing + nearby suggestions
    @State private var typed = ""
    @State private var liveResults: [NearbyAddresses.Suggestion] = []
    @State private var ambient: [NearbyAddresses.Suggestion] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var region: MKCoordinateRegion?

    /// Doors ordered so the ones most worth knocking now (clear time suggestion, fewer attempts)
    /// rise to the top — without disturbing `Territory.sortedDoors` (used by the cards elsewhere).
    private var doors: [NotAtHome] {
        territory.sortedDoors.sorted { a, b in
            let pa = a.returnHint.priority, pb = b.returnHint.priority
            if pa != pb { return pa > pb }
            if a.attemptCount != b.attemptCount { return a.attemptCount < b.attemptCount }
            return a.lastTriedAt > b.lastTriedAt
        }
    }
    private var doNotCalls: [DoNotCall] { territory.sortedDoNotCalls }

    private var existingKeys: Set<String> {
        Set(territory.doors.map { NearbyAddresses.normalize($0.address) })
    }
    private var freshAmbient: [NearbyAddresses.Suggestion] {
        ambient.filter { !existingKeys.contains(NearbyAddresses.normalize($0.address)) }
    }

    var body: some View {
        List {
            infoSection
            if !doNotCalls.isEmpty { doNotCallSection }
            notAtHomeSection
            suggestionsSection
        }
        .navigationTitle(territory.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .fullScreenCover(isPresented: $showCamera) {
            ImagePicker(sourceType: .camera) { image in
                territory.mapImageData = image.jpegData(compressionQuality: 0.8)
                context.saveIfPossible()
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showImageViewer) { imageViewer }
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
        .onChange(of: typed) { _, value in runLiveSearch(value) }
        .task { await loadOnAppear() }
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

    private var doNotCallSection: some View {
        Section("Do not call") {
            ForEach(doNotCalls) { dnc in
                Label {
                    Text(dnc.address)
                } icon: {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.red)
                }
            }
            .onDelete(perform: deleteDoNotCalls)
        }
    }

    private var notAtHomeSection: some View {
        Section(doNotCalls.isEmpty ? "" : "Not-at-homes") {
            if doors.isEmpty {
                Text("No not-at-homes yet. Tap “Add nearest address” or type one below as you walk.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(doors) { door in
                    NotAtHomeRow(door: door)
                        .contentShape(Rectangle())
                        .onTapGesture { answeredDoor = door }
                        .swipeActions(edge: .leading) {
                            Button {
                                door.markTriedAgain(); territory.touch(); context.saveIfPossible()
                            } label: {
                                Label("Tried again", systemImage: "arrow.clockwise")
                            }
                            .tint(.blue)
                            Button {
                                door.decrementTry(); context.saveIfPossible()
                            } label: {
                                Label("Undo try", systemImage: "arrow.uturn.backward")
                            }
                            .tint(.gray)
                            .disabled(door.attemptCount <= 1)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                deleteDoor(door)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                answeredDoor = door
                            } label: {
                                Label("Answered", systemImage: "person.fill.checkmark")
                            }
                            .tint(.green)
                        }
                }
            }
        }
    }

    @ViewBuilder
    private var suggestionsSection: some View {
        if typed.isEmpty, !freshAmbient.isEmpty {
            Section("Suggested nearby") {
                ForEach(freshAmbient) { suggestion in
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
                    if let d = distanceString(to: suggestion) {
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
                TextField("Type an address to add…", text: $typed)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                if !typed.isEmpty {
                    Button { typed = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .glassEffect(in: Capsule())

            // Live matches for what you're typing — right below the field.
            if !typed.isEmpty {
                VStack(spacing: 0) {
                    if liveResults.isEmpty {
                        Text(searching ? "Searching nearby…" : "No matches nearby")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(liveResults.prefix(4)) { suggestion in
                            Button { addSuggestion(suggestion) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
                                    Text(suggestion.address).lineLimit(1).foregroundStyle(.primary)
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 7)
                            }
                            .buttonStyle(.plain)
                            if suggestion.id != liveResults.prefix(4).last?.id { Divider() }
                        }
                    }
                }
            }

            Button {
                Task { await addNearest() }
            } label: {
                HStack(spacing: 8) {
                    if isAdding { ProgressView().tint(.white) } else { Image(systemName: "location.fill") }
                    Text(isAdding ? "Finding address…" : "Add nearest address")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isAdding)
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
        var lines = ["Territory: \(territory.name)"]
        if !doNotCalls.isEmpty {
            lines.append("\nDo not call:")
            lines.append(contentsOf: doNotCalls.map { "• \($0.address)" })
        }
        if !territory.doors.isEmpty {
            lines.append("\nNot-at-homes:")
            lines.append(contentsOf: territory.sortedDoors.map { "• \($0.address) (tried \($0.attemptCount)×)" })
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Actions

    private func loadOnAppear() async {
        guard region == nil else { return }
        if let loc = await location.current() {
            region = MKCoordinateRegion(center: loc.coordinate,
                                        latitudinalMeters: 600, longitudinalMeters: 600)
            await loadAmbient(around: loc.coordinate)
        } else if let c = territory.coordinate {
            region = MKCoordinateRegion(center: c, latitudinalMeters: 800, longitudinalMeters: 800)
            await loadAmbient(around: c)
        }
    }

    private func loadAmbient(around coordinate: CLLocationCoordinate2D) async {
        ambient = await NearbyAddresses.suggestions(around: coordinate, excluding: existingKeys)
    }

    private func runLiveSearch(_ value: String) {
        searchTask?.cancel()
        let q = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { liveResults = []; searching = false; return }
        guard let region else { liveResults = []; return }
        searching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            let results = await NearbyAddresses.search(query: q, near: region, excluding: existingKeys)
            if Task.isCancelled { return }
            liveResults = results
            searching = false
        }
    }

    private func addSuggestion(_ suggestion: NearbyAddresses.Suggestion) {
        let key = NearbyAddresses.normalize(suggestion.address)
        guard !existingKeys.contains(key) else { return }
        let door = NotAtHome(address: suggestion.address,
                             latitude: suggestion.latitude,
                             longitude: suggestion.longitude)
        context.insert(door)
        door.territory = territory
        territory.touch()
        context.saveIfPossible()
        ambient.removeAll { NearbyAddresses.normalize($0.address) == key }
        liveResults.removeAll { NearbyAddresses.normalize($0.address) == key }
        addedCount += 1
        withAnimation { notice = "Added \(suggestion.address)." }
    }

    private func addNearest() async {
        isAdding = true
        defer { isAdding = false }

        guard let loc = await location.current() else {
            withAnimation { notice = "Turn on location to add the nearest address." }
            return
        }
        let coordinate = loc.coordinate
        let address = await AddressGeocoder.address(for: coordinate)
        let resolved = address.isEmpty ? "Dropped location" : address

        if let existing = duplicate(of: resolved, near: coordinate) {
            existing.markTriedAgain()
            territory.touch()
            context.saveIfPossible()
            addedCount += 1
            withAnimation { notice = "Already on your list — marked tried again." }
            return
        }

        let door = NotAtHome(address: resolved,
                             latitude: coordinate.latitude,
                             longitude: coordinate.longitude)
        context.insert(door)
        door.territory = territory
        territory.touch()
        context.saveIfPossible()
        addedCount += 1
        withAnimation { notice = "Added \(resolved)." }
    }

    private func duplicate(of address: String, near coordinate: CLLocationCoordinate2D) -> NotAtHome? {
        let key = NearbyAddresses.normalize(address)
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return territory.doors.first { door in
            if NearbyAddresses.normalize(door.address) == key { return true }
            if let c = door.coordinate {
                return CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: here) < 18
            }
            return false
        }
    }

    private func distanceString(to suggestion: NearbyAddresses.Suggestion) -> String? {
        guard let region else { return nil }
        let origin = CLLocation(latitude: region.center.latitude, longitude: region.center.longitude)
        let there = CLLocation(latitude: suggestion.latitude, longitude: suggestion.longitude)
        return Self.distanceFormatter.string(fromDistance: origin.distance(from: there))
    }

    private static let distanceFormatter: MKDistanceFormatter = {
        let f = MKDistanceFormatter(); f.unitStyle = .abbreviated; return f
    }()

    private func openDirections() {
        guard let c = territory.coordinate else { return }
        let item = MKMapItem(placemark: MKPlacemark(coordinate: c))
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

    private func deleteDoor(_ door: NotAtHome) {
        context.delete(door)
        context.saveIfPossible()
    }

    private func deleteDoNotCalls(_ offsets: IndexSet) {
        for index in offsets { context.delete(doNotCalls[index]) }
        context.saveIfPossible()
    }

    private func deleteTerritory() {
        context.delete(territory)
        context.saveIfPossible()
        dismiss()
    }
}

/// One door row: address, attempt count + last-tried, and a best-time-to-return hint.
private struct NotAtHomeRow: View {
    let door: NotAtHome

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(door.address)
                .accessibilityIdentifier("notAtHome.address")
            HStack(spacing: 6) {
                Text("Tried \(door.attemptCount)×")
                Text("· last \(door.lastTriedAt.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let hint = door.returnHint.text {
                Label(hint, systemImage: door.returnHint.symbol)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.blue)
                    .labelStyle(.titleAndIcon)
                    .accessibilityIdentifier("notAtHome.hint")
            }
        }
        .padding(.vertical, 2)
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
