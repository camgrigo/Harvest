import Foundation
import SwiftData
import CoreLocation

/// Records and reads today's visited locations for the map breadcrumb. On-device, lightweight.
/// Pure date math lives in `pointsToday(from:asOf:calendar:)` so it can be unit-tested directly.
@MainActor
enum VisitTracker {
    /// Record a location as visited (a knocked door, a logged visit, or a location sample).
    static func logVisit(coordinate: CLLocationCoordinate2D,
                         context: String = "location_sample",
                         in modelContext: ModelContext) {
        let log = VisitLog(coordinate: coordinate, context: context)
        modelContext.insert(log)
        modelContext.saveIfPossible()
    }

    /// Today's visits, oldest→newest, for the given day. `fetchLimit` guards against runaway memory.
    static func todaysVisits(from modelContext: ModelContext,
                             asOf now: Date = .now,
                             calendar: Calendar = .current) -> [VisitLog] {
        let startOfDay = calendar.startOfDay(for: now)
        let endOfDay = startOfDay.addingTimeInterval(86_400)
        var descriptor = FetchDescriptor<VisitLog>(
            predicate: #Predicate<VisitLog> { log in
                log.timestamp >= startOfDay && log.timestamp < endOfDay
            },
            sortBy: [SortDescriptor(\VisitLog.timestamp)]
        )
        descriptor.fetchLimit = 5000
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Today's visits as a polyline coordinate sequence for MapKit rendering.
    static func todaysCoordinates(from modelContext: ModelContext,
                                  asOf now: Date = .now,
                                  calendar: Calendar = .current) -> [CLLocationCoordinate2D] {
        todaysVisits(from: modelContext, asOf: now, calendar: calendar).map(\.coordinate)
    }

    /// Pure filter: from an in-memory list of logs, the ones on the same calendar day as `now`,
    /// oldest→newest. Separated from SwiftData so the "today's points" rule is unit-testable.
    static func pointsToday(from logs: [VisitLog],
                            asOf now: Date = .now,
                            calendar: Calendar = .current) -> [VisitLog] {
        let startOfDay = calendar.startOfDay(for: now)
        let endOfDay = startOfDay.addingTimeInterval(86_400)
        return logs
            .filter { $0.timestamp >= startOfDay && $0.timestamp < endOfDay }
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// Purge visit logs older than `days` (called on launch to keep the store small).
    static func purgeOld(olderThan days: Int = 30,
                         from modelContext: ModelContext,
                         asOf now: Date = .now) {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let descriptor = FetchDescriptor<VisitLog>(
            predicate: #Predicate<VisitLog> { $0.timestamp < cutoff }
        )
        guard let stale = try? modelContext.fetch(descriptor), !stale.isEmpty else { return }
        for log in stale { modelContext.delete(log) }
        modelContext.saveIfPossible()
    }
}
