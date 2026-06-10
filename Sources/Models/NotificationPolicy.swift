import Foundation
import UserNotifications

/// The user's preferences for how return-visit reminders behave: on/off and an optional nightly
/// "quiet hours" window during which a reminder is pushed to the morning. A plain `Codable` value
/// type so the date/level math is pure and easy to unit-test, and so it can be persisted as one
/// small blob in `UserDefaults` (it's app-wide, not per-record, so it doesn't need to live in the
/// SwiftData store).
struct NotificationPolicy: Codable, Equatable, Sendable {
    /// Master switch. When off, nothing is scheduled.
    var remindersEnabled: Bool = true
    /// Whether the quiet-hours window is honored at all.
    var quietHoursEnabled: Bool = false
    /// Quiet-hours start hour (24-hour). Defaults to 9 PM.
    var quietHoursStart: Int = 21
    /// Quiet-hours end hour (24-hour). Defaults to 8 AM. May wrap past midnight.
    var quietHoursEnd: Int = 8

    /// The default, used before the user changes anything.
    static let `default` = NotificationPolicy()

    // MARK: Quiet hours (pure)

    /// Whether `date`'s hour lands inside the quiet-hours window. Handles overnight windows that
    /// wrap past midnight (e.g. 21→8). Returns `false` when quiet hours are disabled.
    func isInQuietHours(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard quietHoursEnabled else { return false }
        let hour = calendar.component(.hour, from: date)
        if quietHoursStart == quietHoursEnd { return false }     // empty window
        if quietHoursStart < quietHoursEnd {
            return hour >= quietHoursStart && hour < quietHoursEnd
        } else {
            return hour >= quietHoursStart || hour < quietHoursEnd  // wraps midnight
        }
    }

    /// If `date` is in quiet hours, move it to the end of the window (so a 2 AM reminder fires at
    /// 8 AM). For overnight windows that started "yesterday", the end is the same calendar day; for
    /// a same-day window it's later that day. Returns the unchanged date when no shift is needed.
    func shiftOutOfQuietHours(_ date: Date, calendar: Calendar = .current) -> Date {
        guard isInQuietHours(date, calendar: calendar) else { return date }
        let hour = calendar.component(.hour, from: date)
        // Overnight window and we're in its "early-morning" tail (hour < end): the end is today.
        // Otherwise (we're in the evening part, or it's a same-day window) the end is tomorrow only
        // for overnight windows; for same-day windows the end is later today.
        let endIsNextDay = quietHoursStart > quietHoursEnd && hour >= quietHoursStart
        let base = endIsNextDay ? (calendar.date(byAdding: .day, value: 1, to: date) ?? date) : date
        return calendar.date(bySettingHour: quietHoursEnd, minute: 0, second: 0, of: base) ?? date
    }

    // MARK: Interruption level (pure)

    /// A polite interruption level based on how soon the reminder is due, measured from `now`:
    /// `.timeSensitive` only when it's overdue or due within the hour, `.active` within a day, and
    /// `.passive` for anything further out. This lets iOS's Focus / scheduled-summary handling do
    /// its job for the non-urgent ones instead of always buzzing.
    func interruptionLevel(for fireDate: Date, now: Date = .now) -> UNNotificationInterruptionLevel {
        let hoursUntil = fireDate.timeIntervalSince(now) / 3600
        if hoursUntil < 1 { return .timeSensitive }   // overdue or imminent
        if hoursUntil < 24 { return .active }
        return .passive
    }
}

/// Loads and saves the single app-wide `NotificationPolicy` to `UserDefaults`. Kept tiny and
/// dependency-injectable so tests can use an isolated suite.
enum NotificationPolicyStore {
    private static let key = "harvest.notificationPolicy"

    static func load(from defaults: UserDefaults = .standard) -> NotificationPolicy {
        guard let data = defaults.data(forKey: key),
              let policy = try? JSONDecoder().decode(NotificationPolicy.self, from: data)
        else { return .default }
        return policy
    }

    static func save(_ policy: NotificationPolicy, to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(policy) {
            defaults.set(data, forKey: key)
        }
    }
}
