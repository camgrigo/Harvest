import Foundation
import UserNotifications

/// Schedules the local "go back and visit" reminders. Everything stays on the device.
@MainActor
final class ReminderScheduler {
    static let shared = ReminderScheduler()
    private init() {}

    /// Category + action identifiers used for the actionable buttons on a reminder.
    static let categoryID = "RETURN_VISIT"
    static let markVisitedAction = "MARK_VISITED"
    static let snoozeAction = "SNOOZE_3D"

    /// How far out the "Snooze" button pushes a reminder.
    static let snoozeDays = 3

    func requestAuthorization() async {
        registerActions()
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Registers the "Mark visited" / "Snooze" buttons shown on a reminder. Idempotent.
    func registerActions() {
        let visited = UNNotificationAction(
            identifier: Self.markVisitedAction, title: "Mark visited", options: [])
        let snooze = UNNotificationAction(
            identifier: Self.snoozeAction, title: "Snooze \(Self.snoozeDays) days", options: [])
        let category = UNNotificationCategory(
            identifier: Self.categoryID, actions: [visited, snooze],
            intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Schedule (or reschedule) a return-visit reminder. Always cancels any pending reminder with
    /// the same id first, so a person never accumulates duplicates. Honors the user's
    /// `NotificationPolicy`: off → nothing scheduled; quiet hours → fire date nudged out of the
    /// window; and a polite interruption level by how soon it's due. Pass `policy` to override the
    /// stored one (used by tests); otherwise the saved policy is loaded.
    func schedule(id: UUID, name: String, on date: Date, policy: NotificationPolicy? = nil) {
        let center = UNUserNotificationCenter.current()
        let key = id.uuidString
        center.removePendingNotificationRequests(withIdentifiers: [key])  // cancel before reschedule

        let policy = policy ?? NotificationPolicyStore.load()
        guard policy.remindersEnabled else { return }

        let fireDate = policy.shiftOutOfQuietHours(date)
        guard fireDate > .now else { return }

        let content = UNMutableNotificationContent()
        content.title = "Return visit"
        content.body = "Time to call back on \(name)."
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        // Only buzz with urgency when it's actually due/overdue; let iOS batch the rest.
        content.interruptionLevel = policy.interruptionLevel(for: fireDate)

        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: key, content: content, trigger: trigger))
    }

    func cancel(id: UUID) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [id.uuidString])
    }

    /// Notification identifier for a territory's "turn in / rotate" reminder. Namespaced so it
    /// never collides with a person's return-visit reminder that shares the territory's id space.
    private static func territoryKey(_ id: UUID) -> String { "territory-\(id.uuidString)" }

    /// Schedule (or reschedule) a "turn in this territory" reminder for its due date. Cancels any
    /// pending territory reminder with the same id first, and honors the user's NotificationPolicy
    /// (off → nothing; quiet hours → nudged out of the window), matching `schedule(id:name:on:)`.
    func scheduleTerritoryDue(id: UUID, territoryName: String, on date: Date,
                              policy: NotificationPolicy? = nil) {
        let center = UNUserNotificationCenter.current()
        let key = Self.territoryKey(id)
        center.removePendingNotificationRequests(withIdentifiers: [key])

        let policy = policy ?? NotificationPolicyStore.load()
        guard policy.remindersEnabled else { return }

        let fireDate = policy.shiftOutOfQuietHours(date)
        guard fireDate > .now else { return }

        let content = UNMutableNotificationContent()
        content.title = "Territory due"
        content.body = "Time to turn in or rotate \(territoryName)."
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        content.interruptionLevel = policy.interruptionLevel(for: fireDate)

        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: key, content: content, trigger: trigger))
    }

    func cancelTerritoryDue(id: UUID) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.territoryKey(id)])
    }
}
