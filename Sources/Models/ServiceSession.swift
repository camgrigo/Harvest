import Foundation
import SwiftData

/// A tracked service session: from start to optional completion. Used for in-session timing
/// and rollup into monthly reports. Soft-deleted sessions remain queryable (for reports)
/// but marked as deleted. Lightweight-migration ready: every stored property has a default.
@Model
final class ServiceSession {
    var id: UUID = UUID()
    var startAt: Date = Date.now
    /// nil = the session is still running.
    var endAt: Date? = nil
    /// Territory being worked (optional), for context in reports.
    var territory: Territory? = nil
    /// Freeform notes (e.g. "Apartment complex on Oak").
    var notes: String = ""
    /// Soft-delete timestamp; nil = live. Purged after 30 days on app launch.
    var deletedAt: Date? = nil

    init(startAt: Date = .now,
         territory: Territory? = nil,
         notes: String = "") {
        self.id = UUID()
        self.startAt = startAt
        self.endAt = nil
        self.territory = territory
        self.notes = notes
    }

    /// Duration in seconds, or nil if the session is still active.
    var durationSeconds: Int? {
        guard let endAt else { return nil }
        return Int(endAt.timeIntervalSince(startAt))
    }

    /// True when the session is in progress (no end date set).
    var isActive: Bool { endAt == nil }

    /// Stop the session now.
    func stop(at date: Date = .now) {
        self.endAt = date
    }

    /// Soft-delete the session (hidden from normal queries, recoverable within 30 days).
    func markDeleted(at date: Date = .now) {
        self.deletedAt = date
    }
}
