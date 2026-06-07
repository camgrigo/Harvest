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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            infoActionsSection
            if let summary {
                Section { Text(summary).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            if !person.entries.isEmpty {
                notesSection
            }
        }
        .navigationTitle(person.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
        .onAppear { hasReminder = person.nextVisitDate != nil }
        .onChange(of: person.addressText) { _, _ in regeocode() }
        .safeAreaInset(edge: .bottom) { composerBar }
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
                    Text("Write a note or ask about \(person.name)…")
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
            .disabled(isSummarizing || person.entries.isEmpty)

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
            if person.entries.isEmpty {
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
                }
            }
        }
    }

    // MARK: Actions

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
