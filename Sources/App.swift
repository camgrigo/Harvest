import SwiftUI
import SwiftData
import BackgroundTasks

@main
struct HarvestApp: App {
    let container: ModelContainer
    @StateObject private var notifications = NotificationCoordinator()

    /// The background task that writes a ~daily encrypted backup to iCloud Drive. Listed in
    /// project.yml's BGTaskSchedulerPermittedIdentifiers; must match exactly.
    static let backupTaskIdentifier = "com.camgrigo.harvest.backup"

    init() {
        // UI tests pass "-uitesting" so each launch starts from a clean, ephemeral store.
        // Normal launches share one container with the App Intents (Siri / Shortcuts).
        let uiTesting = ProcessInfo.processInfo.arguments.contains("-uitesting")
        container = uiTesting ? AppModelContainer.make(inMemory: true) : AppModelContainer.shared
        if !uiTesting {
            registerBackgroundTasks(container: container)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(notifications)
                .task { notifications.activate() }
                .task { Self.scheduleAutoBackupTask() }
        }
        .modelContainer(container)
    }

    // MARK: Background backup

    /// Registers the handler once at launch. Re-running the backup re-schedules the next one, so the
    /// task fires roughly daily as long as the system grants background time.
    private func registerBackgroundTasks(container: ModelContainer) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backupTaskIdentifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            Self.handleBackupTask(task, container: container)
        }
    }

    static func scheduleAutoBackupTask() {
        let request = BGProcessingTaskRequest(identifier: backupTaskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = Self.nextBackupDate(after: .now)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            #if DEBUG
            print("Failed to schedule backup task: \(error)")
            #endif
        }
    }

    /// Pure date math (unit-tested): the next backup is ~24h out.
    static func nextBackupDate(after date: Date) -> Date {
        date.addingTimeInterval(24 * 3600)
    }

    private static func handleBackupTask(_ task: BGProcessingTask, container: ModelContainer) {
        task.expirationHandler = { task.setTaskCompleted(success: false) }

        Task { @MainActor in
            // No stored passphrase → nothing to do, but still re-schedule.
            guard let passphrase = BackupService.autoBackupPassphrase(), !passphrase.isEmpty else {
                scheduleAutoBackupTask()
                task.setTaskCompleted(success: true)
                return
            }
            do {
                try BackupService.autoBackupToiCloud(context: container.mainContext, passphrase: passphrase)
                BackupService.pruneOldAutoBackups(olderThan: 30)
                scheduleAutoBackupTask()
                task.setTaskCompleted(success: true)
            } catch {
                #if DEBUG
                print("Auto-backup failed: \(error)")
                #endif
                scheduleAutoBackupTask()
                task.setTaskCompleted(success: false)
            }
        }
    }
}
