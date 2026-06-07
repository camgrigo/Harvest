import SwiftUI
import SwiftData
import MapKit

/// One person's page. At the 70 % sheet detent virtually everything above Notes fits on screen
/// without scrolling. Details are read-only by default; tap Edit to change them. The reminder
/// row expands inline. The iMessage composer is pinned below everything.
struct PersonDetailView: View {
    @Bindable var person: Person
    @Environment(\.modelContext) private var context

    @State private var assistant = Assistant()
    @State private var summary: String?
    @State private var isSummarizing = false
    @State private var hasReminder = false
    @State private var isEditing = false
    @State private var showReminderPicker = false
    @State private var showingDeleteConfirm = false
    @State private var showMapPicker = false
    @State private var suppressRegeocode = false
    @State private var lookAroundScene: MKLookAroundScene?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            if let lookAroundScene {
                Section {
                    LookAroundPreview(initialScene: lookAroundScene)
                        .frame(height: 180)
                        .listRowInsets(EdgeInsets())
                }
            }
            infoActionsSection
            if let summary {
                Section { Text(summary).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            if !person.sortedEntries.isEmpty || !person.recentlyDeletedEntries.isEmpty {
                notesSection
            }
        }
        .navigationTitle(person.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: shareText) { Image(systemName: "square.and.arrow.up") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(isEditing ? "Done" : "Edit") {
                    withAnimation { isEditing.toggle() }
                }
                .fontWeight(isEditing ? .semibold : .regular)
            }
        }
        .confirmationDialog(
            "Delete \(person.name)?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deletePerson() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("All notes and visit history will be permanently removed.")
        }
        .sheet(isPresented: $showMapPicker) {
            LocationPickerView(initial: person.coordinate) { coord, addr in
                person.latitude = coord.latitude
                person.longitude = coord.longitude
                let trimmed = addr.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, trimmed != person.addressText {
                    suppressRegeocode = true
                    person.addressText = trimmed
                }
                context.saveIfPossible()
            }
        }
        .onAppear { hasReminder = person.nextVisitDate != nil }
        .onChange(of: person.addressText) { _, _ in
            if suppressRegeocode { suppressRegeocode = false; return }
            regeocode()
        }
        .task(id: coordKey) { await loadLookAround() }
        .safeAreaInset(edge: .bottom) { composerBar }
    }

    // MARK: Share

    /// A plain-text card for the share sheet: name, address, status, next visit, and recent notes.
    private var shareText: String {
        var lines = [person.name]
        if !person.addressText.isEmpty { lines.append(person.addressText) }
        lines.append("Status: \(person.interest.label)")
        if let next = person.nextVisitDate {
            lines.append("Next visit: \(next.formatted(date: .abbreviated, time: .omitted))")
        }
        let entries = person.sortedEntries.reversed().prefix(5)
        if !entries.isEmpty {
            lines.append("\nNotes:")
            lines.append(contentsOf: entries.map {
                "• \($0.date.formatted(date: .abbreviated, time: .omitted)): \($0.text)"
            })
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Chat bar

    private var composerBar: some View {
        NavigationLink {
            ConversationView(person: person, autofocusInput: true)
                .navigationTitle(person.name)
                .navigationBarTitleDisplayMode(.inline)
        } label: {
            HStack(spacing: 10) {
                HStack {
                    Text("Note or ask…")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(in: Capsule())

                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: Combined info + actions section

    /// All the "above the fold" content: editable fields or read-only labels, the two
    /// quick-action rows (Directions, Summarize), and the collapsible reminder row.
    /// Keeping them in one Section removes the extra inter-section gap so everything
    /// packs tightly enough to fit inside a 70 % detent.
    private var infoActionsSection: some View {
        Section {
            // ── Editable fields ──────────────────────────────────────────────
            if isEditing {
                TextField("Name", text: $person.name)
                TextField("Address", text: $person.addressText, axis: .vertical)
                Button {
                    showMapPicker = true
                } label: {
                    Label("Choose on map", systemImage: "mappin.and.ellipse")
                }
                Picker("Status", selection: $person.interest) {
                    ForEach(InterestLevel.allCases) { level in
                        Label(level.label, systemImage: level.symbol).tag(level)
                    }
                }
                Button("Delete", role: .destructive) {
                    showingDeleteConfirm = true
                }
            } else {
                // ── Read-only display ─────────────────────────────────────────
                if !person.addressText.isEmpty {
                    LabeledContent("Address", value: person.addressText)
                }
                LabeledContent("Status") {
                    Label(person.interest.label, systemImage: person.interest.symbol)
                        .foregroundStyle(.secondary)
                }
            }

            // ── Actions ───────────────────────────────────────────────────────
            if !person.addressText.isEmpty {
                MapsLinkRow(title: "Directions",
                            address: person.addressText,
                            coordinate: person.coordinate)
            }

            Button {
                Task { await makeSummary() }
            } label: {
                if isSummarizing {
                    HStack(spacing: 8) { ProgressView(); Text("Summarizing…") }
                } else {
                    Label("Summarize notes", systemImage: "text.append")
                }
            }
            .disabled(isSummarizing || person.sortedEntries.isEmpty)

            // ── Reminder ──────────────────────────────────────────────────────
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showReminderPicker.toggle() }
            } label: {
                HStack {
                    Label(reminderLabel, systemImage: hasReminder ? "bell.fill" : "bell")
                        .foregroundStyle(hasReminder ? .primary : .secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showReminderPicker ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if showReminderPicker {
                Toggle("Remind me to return", isOn: reminderToggle)
                if hasReminder {
                    DatePicker(
                        "On",
                        selection: Binding(
                            get: { person.nextVisitDate ?? ReminderTime.morning(of: .now) },
                            set: { newValue in
                                person.nextVisitDate = newValue
                                ReminderScheduler.shared.schedule(
                                    id: person.id, name: person.name, on: newValue)
                            }
                        ),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }
            }
        }
    }

    private var reminderLabel: String {
        guard let date = person.nextVisitDate else { return "No reminder" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var reminderToggle: Binding<Bool> {
        Binding(
            get: { hasReminder },
            set: { on in
                hasReminder = on
                if on {
                    let date = person.nextVisitDate
                        ?? ReminderTime.morning(of: Calendar.current.date(
                               byAdding: .day, value: 3, to: .now)!)
                    person.nextVisitDate = date
                    ReminderScheduler.shared.schedule(id: person.id, name: person.name, on: date)
                } else {
                    person.nextVisitDate = nil
                    ReminderScheduler.shared.cancel(id: person.id)
                }
            }
        )
    }

    // MARK: Notes

    private var notesSection: some View {
        Section("Notes") {
            if person.sortedEntries.isEmpty {
                Text("No notes yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(person.sortedEntries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(entry.text)
                    }
                    .padding(.vertical, 2)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { softDelete(entry) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            if !person.recentlyDeletedEntries.isEmpty {
                NavigationLink {
                    RecentlyDeletedView(person: person)
                } label: {
                    Label("Recently Deleted (\(person.recentlyDeletedEntries.count))", systemImage: "trash")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func softDelete(_ entry: JournalEntry) {
        entry.deletedAt = .now
        context.saveIfPossible()
    }

    // MARK: Actions

    /// Changes whenever the pin moves, so the Look Around scene re-fetches on address edits.
    private var coordKey: String {
        guard let c = person.coordinate else { return "" }
        return String(format: "%.5f,%.5f", c.latitude, c.longitude)
    }

    private func loadLookAround() async {
        guard let c = person.coordinate else { lookAroundScene = nil; return }
        lookAroundScene = await Self.loadScene(at: c)
    }

    /// Fetched off the main actor (the request/scene are non-Sendable); `sending` returns it safely.
    private nonisolated static func loadScene(at coordinate: CLLocationCoordinate2D) async -> sending MKLookAroundScene? {
        try? await MKLookAroundSceneRequest(coordinate: coordinate).scene
    }

    private func makeSummary() async {
        isSummarizing = true
        defer { isSummarizing = false }
        summary = await assistant.summarize(name: person.name, entries: person.sortedEntries)
    }

    private func deletePerson() {
        ReminderScheduler.shared.cancel(id: person.id)
        context.delete(person)
        context.saveIfPossible()
        dismiss()
    }

    private func regeocode() {
        person.latitude = nil
        person.longitude = nil
        Task { await locate() }
    }

    private func locate() async {
        let address = person.addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return }
        if let coord = await AddressGeocoder.coordinate(for: address) {
            person.latitude = coord.latitude
            person.longitude = coord.longitude
        }
    }
}
