import SwiftUI
import SwiftData

/// A personal list of service plans — upcoming and past — kept just for you. Add one with when,
/// where you'll meet, who you're going with, and a note; optionally mirror it to Apple Calendar.
struct ServicePlansView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ServicePlan.date) private var plans: [ServicePlan]
    @Query private var doors: [NotAtHome]

    @State private var editing: ServicePlan?
    @State private var addingNew = false
    @State private var selectedDate: Date = .now

    private var upcoming: [ServicePlan] { plans.filter(\.isUpcoming) }
    private var past: [ServicePlan] { plans.filter { !$0.isUpcoming }.reversed() }

    /// Projected future dates for recurring plans (the originals aren't stored repeatedly — they're
    /// expanded on the fly), looking ahead a few months so the Calendar tab shows what's coming.
    private var upcomingOccurrences: [RecurringOccurrence] {
        RecurringOccurrence.upcoming(from: plans)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DatePicker("Date", selection: $selectedDate, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                notAtHomeTip
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
                            if !upcomingOccurrences.isEmpty {
                                Section("Repeats") {
                                    ForEach(upcomingOccurrences) { occurrence in
                                        Button { editing = occurrence.plan } label: {
                                            HStack(spacing: 10) {
                                                Image(systemName: "repeat")
                                                    .foregroundStyle(.secondary)
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(occurrence.date.formatted(.dateTime.weekday(.abbreviated).month().day().hour().minute()))
                                                        .font(.subheadline.weight(.medium))
                                                    Text(occurrence.plan.recurrenceKind.label)
                                                        .font(.caption).foregroundStyle(.secondary)
                                                }
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    }
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
            }
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    ServiceSessionControlView()
                    addBar
                }
            }
            .sheet(item: $editing) { plan in PlanEditor(plan: plan) }
            .sheet(isPresented: $addingNew) { NewServicePlanView(initialDate: selectedDate) }
        }
    }

    /// Bottom action that opens a new plan pre-seeded with the calendar's selected date.
    private var addBar: some View {
        Button { addingNew = true } label: {
            Label("New plan · \(selectedDate.formatted(.dateTime.month(.abbreviated).day()))",
                  systemImage: "plus.circle.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Aggregate "best time to retry not-at-homes" suggestion from every door's knock history.
    private var notAtHomeAdvice: NotAtHomeAdvice? {
        NotAtHomeAdvice(doors: doors.map(\.attemptTimes))
    }

    @ViewBuilder
    private var notAtHomeTip: some View {
        if let advice = notAtHomeAdvice {
            HStack(spacing: 12) {
                Image(systemName: advice.bucket.symbol)
                    .font(.title3)
                    .foregroundStyle(.orange)
                    .frame(width: 40, height: 40)
                    .background(Color.orange.opacity(0.15), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Best time for not-at-homes: \(advice.bucket.single.capitalized)")
                        .font(.subheadline.weight(.semibold))
                    Text("\(advice.doorsToTry) of \(advice.totalDoors) door\(advice.totalDoors == 1 ? "" : "s") not knocked then")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Plan") { planNotAtHomeSession(advice) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal)
            .padding(.bottom, 6)
        }
    }

    /// Open a new plan pre-seeded to the suggested part of the selected day.
    private func planNotAtHomeSession(_ advice: NotAtHomeAdvice) {
        let cal = Calendar.current
        selectedDate = cal.date(bySettingHour: advice.bucket.planHour, minute: 0, second: 0,
                                of: selectedDate) ?? selectedDate
        addingNew = true
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

/// A single projected future date for a recurring plan. The plan itself is stored once; its later
/// occurrences are computed here so the Calendar tab can show "what's coming" without duplicating
/// records. Pure value type so the expansion math is unit-testable.
struct RecurringOccurrence: Identifiable {
    let id = UUID()
    let plan: ServicePlan
    let date: Date

    /// Expand every recurring plan into its upcoming occurrences within `horizon` of `now`, sorted
    /// by date. Non-recurring plans contribute nothing (they already show in the normal sections).
    static func upcoming(
        from plans: [ServicePlan],
        now: Date = .now,
        horizon: DateComponents = DateComponents(month: 3),
        calendar: Calendar = .current
    ) -> [RecurringOccurrence] {
        guard let cutoff = calendar.date(byAdding: horizon, to: now) else { return [] }
        var result: [RecurringOccurrence] = []
        for plan in plans where plan.recurrenceKind != .none {
            let kind = plan.recurrenceKind
            var cursor = plan.date
            var guardCount = 0
            while let next = kind.nextDate(after: cursor, calendar: calendar),
                  next <= cutoff, guardCount < 200 {
                if next > now { result.append(RecurringOccurrence(plan: plan, date: next)) }
                cursor = next
                guardCount += 1
            }
        }
        return result.sorted { $0.date < $1.date }
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
    @State private var recurrence: String
    @State private var addToCalendar: Bool
    @State private var calendarError: String?

    init(plan: ServicePlan?) {
        self.plan = plan
        _date = State(initialValue: plan?.date ?? PlanEditor.defaultStart())
        _place = State(initialValue: plan?.place ?? "")
        _partner = State(initialValue: plan?.partner ?? "")
        _note = State(initialValue: plan?.note ?? "")
        _recurrence = State(initialValue: plan?.recurrence ?? RecurrenceKind.none.rawValue)
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
                Section("Repeat") {
                    Picker("Repeat", selection: $recurrence) {
                        ForEach(RecurrenceKind.allCases, id: \.rawValue) { kind in
                            Text(kind.label).tag(kind.rawValue)
                        }
                    }
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
            plan.recurrence = recurrence
            target = plan
        } else {
            let new = ServicePlan(date: date, place: place, partner: partner, note: note,
                                  recurrence: recurrence)
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
