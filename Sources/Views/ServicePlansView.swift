import SwiftUI
import SwiftData

/// A personal list of service plans — upcoming and past — kept just for you. Add one with when,
/// where you'll meet, who you're going with, and a note; optionally mirror it to Apple Calendar.
struct ServicePlansView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ServicePlan.date) private var plans: [ServicePlan]

    @State private var editing: ServicePlan?
    @State private var addingNew = false

    private var upcoming: [ServicePlan] { plans.filter(\.isUpcoming) }
    private var past: [ServicePlan] { plans.filter { !$0.isUpcoming }.reversed() }

    var body: some View {
        NavigationStack {
            Group {
                if plans.isEmpty {
                    ContentUnavailableView(
                        "No service plans",
                        systemImage: "calendar",
                        description: Text("Plan a time in the ministry — when, where you'll meet, and who you're going with.")
                    )
                } else {
                    List {
                        if !upcoming.isEmpty {
                            Section("Upcoming") {
                                ForEach(upcoming) { planRow($0) }
                                    .onDelete { delete(upcoming, $0) }
                            }
                        }
                        if !past.isEmpty {
                            Section("Past") {
                                ForEach(past) { planRow($0) }
                                    .onDelete { delete(past, $0) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Service Plans")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { addingNew = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $editing) { plan in PlanEditor(plan: plan) }
            .sheet(isPresented: $addingNew) { PlanEditor(plan: nil) }
        }
    }

    private func planRow(_ plan: ServicePlan) -> some View {
        Button {
            editing = plan
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(plan.date.formatted(.dateTime.weekday(.abbreviated).month().day().hour().minute()))
                    .font(.headline)
                if !plan.place.isEmpty {
                    Label(plan.place, systemImage: "mappin.and.ellipse")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if !plan.partner.isEmpty {
                    Label(plan.partner, systemImage: "person.2")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if !plan.note.isEmpty {
                    Text(plan.note).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    private func delete(_ list: [ServicePlan], _ offsets: IndexSet) {
        for index in offsets { context.delete(list[index]) }
        context.saveIfPossible()
    }
}

/// Add or edit a single plan. On save, optionally mirrors it to Apple Calendar.
private struct PlanEditor: View {
    let plan: ServicePlan?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var date: Date
    @State private var place: String
    @State private var partner: String
    @State private var note: String
    @State private var addToCalendar: Bool
    @State private var calendarError: String?

    init(plan: ServicePlan?) {
        self.plan = plan
        _date = State(initialValue: plan?.date ?? PlanEditor.defaultStart())
        _place = State(initialValue: plan?.place ?? "")
        _partner = State(initialValue: plan?.partner ?? "")
        _note = State(initialValue: plan?.note ?? "")
        _addToCalendar = State(initialValue: false)
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("When", selection: $date)
                    .datePickerStyle(.graphical)
                Section("Where") {
                    TextField("Meeting place", text: $place)
                }
                Section("With") {
                    TextField("Who you're going with", text: $partner).textContentType(.name)
                }
                Section("Notes") {
                    TextField("e.g. bring magazines, work Oak St territory", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                }
                Toggle("Add to Apple Calendar", isOn: $addToCalendar)
            }
            .navigationTitle(plan == nil ? "New Plan" : "Edit Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
            .alert("Calendar", isPresented: Binding(get: { calendarError != nil },
                                                    set: { if !$0 { calendarError = nil } })) {
                Button("OK", role: .cancel) { dismiss() }
            } message: {
                Text(calendarError ?? "")
            }
        }
    }

    private func save() {
        let target: ServicePlan
        if let plan {
            plan.date = date
            plan.place = place
            plan.partner = partner
            plan.note = note
            target = plan
        } else {
            let new = ServicePlan(date: date, place: place, partner: partner, note: note)
            context.insert(new)
            target = new
        }
        context.saveIfPossible()

        if addToCalendar {
            Task {
                do {
                    try await CalendarExport.add(target)
                    dismiss()
                } catch {
                    calendarError = error.localizedDescription
                }
            }
        } else {
            dismiss()
        }
    }

    /// The next hour, on the hour — a sensible default for a new plan.
    private static func defaultStart() -> Date {
        let calendar = Calendar.current
        let nextHour = calendar.date(byAdding: .hour, value: 1, to: .now) ?? .now
        let comps = calendar.dateComponents([.year, .month, .day, .hour], from: nextHour)
        return calendar.date(from: comps) ?? nextHour
    }
}
