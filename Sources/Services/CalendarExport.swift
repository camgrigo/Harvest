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
        guard try await store.requestWriteOnlyAccessToEvents() else { throw CalendarError.denied }

        let event = EKEvent(eventStore: store)
        // The partner goes in the title (not the notes) so the event reads "Field service with John".
        event.title = plan.partner.isEmpty ? "Field service" : "Field service with \(plan.partner)"
        event.startDate = plan.date
        event.endDate = plan.end
        // The meeting place is the event's location.
        if !plan.place.isEmpty { event.location = plan.place }

        if !plan.note.isEmpty { event.notes = plan.note }

        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent)
    }
}
