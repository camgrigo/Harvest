import SwiftUI
import SwiftData
import CoreLocation
import UIKit

/// A Calendar-style "smart compose" for adding a return visit. You type a natural-language note up
/// top; as you type, the structured fields below (name, reminder, interest, address) fill in live
/// via the fast `FallbackParser`. Every field is also directly editable, and a manual edit is never
/// overwritten by a later parse. Confirming builds the Person, then geocodes the address and writes
/// a one-line headline in the background.
struct NewPersonView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// Called with the freshly created person so the caller can focus/open it.
    var onCreated: (Person) -> Void

    // The natural-language box — the source the fields are extracted from, and the first note.
    @State private var noteText = ""
    @FocusState private var noteFocused: Bool

    // Structured fields + a "user touched this" flag each, so live parsing won't stomp manual edits.
    @State private var name = "";        @State private var nameEdited = false
    @State private var address = "";     @State private var addressEdited = false
    @State private var interest: InterestLevel = .new
    @State private var interestEdited = false
    @State private var hasReminder = false
    @State private var reminderDate = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
    @State private var reminderEdited = false

    private var canCreate: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    smartBox
                    fields
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("New Person")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { create() } label: {
                        Image(systemName: "checkmark").fontWeight(.bold)
                    }
                    .disabled(!canCreate)
                    .accessibilityLabel("Add person")
                }
            }
            .onAppear { noteFocused = true }
        }
    }

    // MARK: Natural-language box

    private var smartBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Met Maria at 14 Elm St — interested, visit Thursday",
                      text: $noteText, axis: .vertical)
                .focused($noteFocused)
                .lineLimit(2...6)
                .font(.body)
                .onChange(of: noteText) { _, newValue in applyParse(newValue) }
            Text("Type naturally — the fields below fill in as you go, and you can tweak any of them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Editable fields

    private var fields: some View {
        VStack(spacing: 12) {
            // Name — with the accent bar, like Calendar's title.
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(.tint).frame(width: 4, height: 30)
                TextField("Name", text: nameBinding)
                    .font(.title3.weight(.semibold))
                    .fontDesign(.serif)
                    .textInputAutocapitalization(.words)
            }
            .cardRow()

            // Reminder to return.
            VStack(spacing: 8) {
                Toggle(isOn: hasReminderBinding) {
                    Label("Reminder to return", systemImage: "bell.fill")
                }
                if hasReminder {
                    Divider()
                    DatePicker("When", selection: reminderDateBinding, displayedComponents: .date)
                }
            }
            .cardRow()

            // Interest.
            HStack {
                Label("Interest", systemImage: "leaf.fill")
                Spacer(minLength: 8)
                Picker("Interest", selection: interestBinding) {
                    ForEach(InterestLevel.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .labelsHidden()
            }
            .cardRow()

            // Address.
            HStack(spacing: 10) {
                Image(systemName: "mappin.and.ellipse").foregroundStyle(.secondary)
                TextField("Address (optional)", text: addressBinding)
                    .textInputAutocapitalization(.words)
            }
            .cardRow()
        }
    }

    // MARK: Live parsing

    /// Re-extract the structured fields from the note, leaving any field the user has touched alone.
    private func applyParse(_ text: String) {
        let parsed = FallbackParser.parse(text)
        if !nameEdited { name = parsed.personName }
        if !addressEdited { address = parsed.address }
        if !interestEdited, let level = parsed.interest.level { interest = level }
        if !reminderEdited, let date = DateFormatter.ymd.date(from: parsed.followUpDate) {
            reminderDate = date
            hasReminder = true
        }
    }

    // Edit-aware bindings: writing through marks the field user-edited, so `applyParse` (which
    // mutates the @State directly) fills it in but a manual edit pins it.

    private var nameBinding: Binding<String> {
        Binding(get: { name }, set: { name = $0; nameEdited = true })
    }
    private var addressBinding: Binding<String> {
        Binding(get: { address }, set: { address = $0; addressEdited = true })
    }
    private var interestBinding: Binding<InterestLevel> {
        Binding(get: { interest }, set: { interest = $0; interestEdited = true })
    }
    private var hasReminderBinding: Binding<Bool> {
        Binding(get: { hasReminder }, set: { hasReminder = $0; reminderEdited = true })
    }
    private var reminderDateBinding: Binding<Date> {
        Binding(get: { reminderDate }, set: { reminderDate = $0; reminderEdited = true })
    }

    // MARK: Create

    private func create() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let person = Person(name: trimmedName)
        context.insert(person)
        person.interest = interest

        let addr = address.trimmingCharacters(in: .whitespacesAndNewlines)
        person.addressText = addr

        let note = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            context.insert(JournalEntry(text: note, person: person))
        }

        if hasReminder {
            let when = ReminderTime.morning(of: reminderDate)
            person.nextVisitDate = when
            ReminderScheduler.shared.schedule(id: person.id, name: person.name, on: when)
        }

        context.saveIfPossible()

        // Background enrichment: drop a pin from the address, and write the one-line gist.
        Task { @MainActor in
            if !addr.isEmpty, person.coordinate == nil,
               let coord = await AddressGeocoder.coordinate(for: addr) {
                person.latitude = coord.latitude
                person.longitude = coord.longitude
            }
            person.headline = await Assistant().headline(name: person.name, entries: person.sortedEntries)
            context.saveIfPossible()
        }

        onCreated(person)
        dismiss()
    }
}

private extension View {
    /// A white grouped-style row tile used by the editable fields.
    func cardRow() -> some View {
        self
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
