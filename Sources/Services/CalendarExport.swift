import Foundation
import EventKit

/// Adds a service plan to a calendar the user picks. Requires full access (to list calendars);
/// the app only ever writes the events you ask it to.
enum CalendarExport {
    /// A lightweight, Sendable view of a writable calendar for the picker.
    struct CalendarOption: Identifiable, Hashable, Sendable {
        let id: String      // EKCalendar.calendarIdentifier
        let title: String
    }

    enum CalendarError: LocalizedError {
        case denied
        var errorDescription: String? {
            "Calendar access was denied. You can turn it on in Settings."
        }
    }

    /// The calendars the user can add to, alphabetised.
    @MainActor
    static func calendars() async throws -> [CalendarOption] {
        let store = EKEventStore()
        guard try await store.requestFullAccessToEvents() else { throw CalendarError.denied }
        return store.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .map { CalendarOption(id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    @MainActor
    static func add(_ plan: ServicePlan, calendarID: String?) async throws {
        let store = EKEventStore()
        guard try await store.requestFullAccessToEvents() else { throw CalendarError.denied }

        let event = EKEvent(eventStore: store)
        event.title = "Field service"
        event.startDate = plan.date
        event.endDate = plan.end
        if !plan.place.isEmpty { event.location = plan.place }

        var lines: [String] = []
        if !plan.partner.isEmpty { lines.append("With \(plan.partner)") }
        if !plan.note.isEmpty { lines.append(plan.note) }
        if !lines.isEmpty { event.notes = lines.joined(separator: "\n") }

        event.calendar = calendarID.flatMap { store.calendar(withIdentifier: $0) }
            ?? store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent)
    }
}
