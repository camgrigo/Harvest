import SwiftUI
import SwiftData
import UIKit

/// A "smart compose" for adding a service plan, mirroring `NewPersonView`. Type a natural-language
/// line up top ("Sat 9am at the Kingdom Hall with John — bring tracts") and the structured fields
/// below — when, where, who with — fill in live via the offline `ServicePlanParser`. Every field
/// stays directly editable, and a manual edit is never overwritten by a later parse.
struct NewServicePlanView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// The natural-language box — the source the fields are extracted from, and the note's basis.
    @State private var text = ""
    @FocusState private var textFocused: Bool

    // Structured fields + a "user touched this" flag each, so live parsing won't stomp manual edits.
    @State private var date = NewServicePlanView.defaultStart()
    @State private var dateEdited = false
    @State private var place = "";    @State private var placeEdited = false
    @State private var partner = "";  @State private var partnerEdited = false

    @State private var addToCalendar = false
    @State private var calendarError: String?

    private var canCreate: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !place.trimmingCharacters(in: .whitespaces).isEmpty
        || !partner.trimmingCharacters(in: .whitespaces).isEmpty
    }

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
            .navigationTitle("New Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { save() } label: {
                        Image(systemName: "checkmark").fontWeight(.bold)
                    }
                    .disabled(!canCreate)
                    .accessibilityLabel("Add plan")
                }
            }
            .onAppear { textFocused = true }
            .alert("Calendar", isPresented: Binding(get: { calendarError != nil },
                                                    set: { if !$0 { calendarError = nil } })) {
                Button("OK", role: .cancel) { dismiss() }
            } message: {
                Text(calendarError ?? "")
            }
        }
    }

    // MARK: Natural-language box

    private var smartBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Sat 9am at the Kingdom Hall with John — bring tracts",
                      text: $text, axis: .vertical)
                .focused($textFocused)
                .lineLimit(2...6)
                .font(.body)
                .onChange(of: text) { _, newValue in applyParse(newValue) }
            Text("Type naturally — the details below fill in as you go, and you can tweak any of them.")
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
            // When — the headline field, with the accent bar like Calendar's title.
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(.tint).frame(width: 4, height: 30)
                DatePicker("When", selection: dateBinding)
                    .labelsHidden()
                Spacer(minLength: 0)
            }
            .cardRow()

            // Where you'll meet.
            HStack(spacing: 10) {
                Image(systemName: "mappin.and.ellipse").foregroundStyle(.secondary)
                TextField("Where you'll meet (optional)", text: placeBinding)
                    .textInputAutocapitalization(.words)
            }
            .cardRow()

            // Who you're going with.
            HStack(spacing: 10) {
                Image(systemName: "person.2.fill").foregroundStyle(.secondary)
                TextField("Who you're going with (optional)", text: partnerBinding)
                    .textContentType(.name)
                    .textInputAutocapitalization(.words)
            }
            .cardRow()

            // Mirror to Apple Calendar.
            Toggle(isOn: $addToCalendar) {
                Label("Add to Apple Calendar", systemImage: "calendar")
            }
            .cardRow()
        }
    }

    // MARK: Live parsing

    /// Re-extract the structured fields from the note, leaving any field the user has touched alone.
    private func applyParse(_ input: String) {
        let parsed = ServicePlanParser.parse(input)
        if !dateEdited, let date = parsed.date { self.date = date }
        if !placeEdited { place = parsed.place }
        if !partnerEdited { partner = parsed.partner }
    }

    // Edit-aware bindings: writing through marks the field user-edited, so `applyParse` (which
    // mutates the @State directly) fills it in but a manual edit pins it.

    private var dateBinding: Binding<Date> {
        Binding(get: { date }, set: { date = $0; dateEdited = true })
    }
    private var placeBinding: Binding<String> {
        Binding(get: { place }, set: { place = $0; placeEdited = true })
    }
    private var partnerBinding: Binding<String> {
        Binding(get: { partner }, set: { partner = $0; partnerEdited = true })
    }

    // MARK: Create

    private func save() {
        let plan = ServicePlan(
            date: date,
            place: place.trimmingCharacters(in: .whitespacesAndNewlines),
            partner: partner.trimmingCharacters(in: .whitespacesAndNewlines),
            note: ServicePlanParser.parse(text).note
        )
        context.insert(plan)
        context.saveIfPossible()

        if addToCalendar {
            Task {
                do {
                    try await CalendarExport.add(plan)
                    dismiss()
                } catch {
                    calendarError = error.localizedDescription
                }
            }
        } else {
            dismiss()
        }
    }

    /// The next hour, on the hour — a sensible default until a time is typed.
    private static func defaultStart() -> Date {
        let cal = Calendar.current
        let nextHour = cal.date(byAdding: .hour, value: 1, to: .now) ?? .now
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: nextHour)
        return cal.date(from: comps) ?? nextHour
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
