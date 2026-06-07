import Foundation
import EventKit

/// Adds a service plan to Apple Calendar (write-only access). On-device; nothing is read back.
enum CalendarExport {
    enum CalendarError: LocalizedError {
        case denied
        var errorDescription: String? {
            "Calendar access was denied. You can turn it on in Settings."
        }
    }

    @MainActor
    static func add(_ plan: ServicePlan) async throws {
        let store = EKEventStore()
        let granted = try await store.requestWriteOnlyAccessToEvents()
        guard granted else { throw CalendarError.denied }

        let event = EKEvent(eventStore: store)
        event.title = "Field service"
        event.startDate = plan.date
        event.endDate = plan.end
        if !plan.place.isEmpty { event.location = plan.place }

        var lines: [String] = []
        if !plan.partner.isEmpty { lines.append("With \(plan.partner)") }
        if !plan.note.isEmpty { lines.append(plan.note) }
        if !lines.isEmpty { event.notes = lines.joined(separator: "\n") }

        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent)
    }
}
