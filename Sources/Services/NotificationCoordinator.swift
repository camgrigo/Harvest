import Foundation
import UserNotifications

/// Receives reminder taps and tells the UI which person to open. Also lets reminders show as
/// banners while the app is in the foreground.
@MainActor
final class NotificationCoordinator: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    /// Set when the user taps a reminder; the UI observes this and opens that person's page.
    @Published var tappedPersonID: UUID?
    /// Set when the user taps a reminder's action button ("Mark visited" / "Snooze").
    @Published var pendingAction: ReminderAction?

    /// An action button the user tapped on a reminder, to be applied to that person.
    struct ReminderAction: Equatable {
        enum Kind { case markVisited, snooze }
        let personID: UUID
        let kind: Kind
    }

    /// Register as the notification delegate and the action buttons. Safe to call once at launch.
    func activate() {
        UNUserNotificationCenter.current().delegate = self
        ReminderScheduler.shared.registerActions()
    }

    // Show reminders as banners even when the app is open.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // Handle a tap on a reminder — either the notification itself or one of its action buttons.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = UUID(uuidString: response.notification.request.identifier)
        let action = response.actionIdentifier
        Task { @MainActor [weak self] in
            guard let self, let id else { return }
            switch action {
            case ReminderScheduler.markVisitedAction:
                self.pendingAction = ReminderAction(personID: id, kind: .markVisited)
            case ReminderScheduler.snoozeAction:
                self.pendingAction = ReminderAction(personID: id, kind: .snooze)
            default:
                self.tappedPersonID = id   // tapped the body → open their page
            }
        }
        completionHandler()
    }
}
