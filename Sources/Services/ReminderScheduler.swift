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

    func schedule(id: UUID, name: String, on date: Date) {
        let center = UNUserNotificationCenter.current()
        let key = id.uuidString
        center.removePendingNotificationRequests(withIdentifiers: [key])
        guard date > .now else { return }

        let content = UNMutableNotificationContent()
        content.title = "Return visit"
        content.body = "Time to call back on \(name)."
        content.sound = .default
        content.categoryIdentifier = Self.categoryID

        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: date
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: key, content: content, trigger: trigger))
    }

    func cancel(id: UUID) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [id.uuidString])
    }
}
