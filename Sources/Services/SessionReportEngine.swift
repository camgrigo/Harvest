import Foundation
import SwiftData

/// Aggregates service sessions into monthly reports and statistics. Pure/injectable so the
/// rollup math is unit-testable with an in-memory store.
@MainActor
enum SessionReportEngine {

    /// Completed (ended), non-deleted sessions whose start falls in the given calendar month.
    static func sessionsInMonth(year: Int, month: Int,
                                context: ModelContext,
                                calendar: Calendar = .current) -> [ServiceSession] {
        guard let startOfMonth = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let startOfNextMonth = calendar.date(byAdding: .month, value: 1, to: startOfMonth)
        else { return [] }

        // Note: #Predicate can't reference computed properties, so we test endAt != nil directly.
        let descriptor = FetchDescriptor<ServiceSession>(
            predicate: #Predicate {
                $0.deletedAt == nil &&
                $0.endAt != nil &&
                $0.startAt >= startOfMonth &&
                $0.startAt < startOfNextMonth
            },
            sortBy: [SortDescriptor(\.startAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Total hours of completed sessions in the given month.
    static func totalHours(year: Int, month: Int,
                           context: ModelContext,
                           calendar: Calendar = .current) -> Double {
        let seconds = sessionsInMonth(year: year, month: month, context: context, calendar: calendar)
            .compactMap(\.durationSeconds)
            .reduce(0, +)
        return Double(seconds) / 3600.0
    }

    /// Count of completed sessions in the given month.
    static func sessionCount(year: Int, month: Int,
                             context: ModelContext,
                             calendar: Calendar = .current) -> Int {
        sessionsInMonth(year: year, month: month, context: context, calendar: calendar).count
    }

    /// This calendar month's stats (year, month, hour total, completed-session count).
    static func thisMonthStats(context: ModelContext,
                               now: Date = .now,
                               calendar: Calendar = .current) -> (year: Int, month: Int, hours: Double, count: Int) {
        let comps = calendar.dateComponents([.year, .month], from: now)
        let year = comps.year ?? 1
        let month = comps.month ?? 1
        return (year, month,
                totalHours(year: year, month: month, context: context, calendar: calendar),
                sessionCount(year: year, month: month, context: context, calendar: calendar))
    }

    /// Purge soft-deleted sessions older than 30 days (called on app launch). Returns the count removed.
    @discardableResult
    static func purgeSoftDeleted(context: ModelContext,
                                 now: Date = .now,
                                 calendar: Calendar = .current) -> Int {
        let cutoff = calendar.date(byAdding: .day, value: -30, to: now) ?? .distantPast
        let descriptor = FetchDescriptor<ServiceSession>(
            predicate: #Predicate { $0.deletedAt != nil && $0.deletedAt! < cutoff }
        )
        let toDelete = (try? context.fetch(descriptor)) ?? []
        toDelete.forEach { context.delete($0) }
        if !toDelete.isEmpty { context.saveIfPossible() }
        return toDelete.count
    }
}
