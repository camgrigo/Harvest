import SwiftUI
import SwiftData

@main
struct ReturnVisitNotebookApp: App {
    let container: ModelContainer
    @StateObject private var notifications = NotificationCoordinator()

    init() {
        // UI tests pass "-uitesting" so each launch starts from a clean, ephemeral store.
        // Normal launches share one container with the App Intents (Siri / Shortcuts).
        let uiTesting = ProcessInfo.processInfo.arguments.contains("-uitesting")
        container = uiTesting ? AppModelContainer.make(inMemory: true) : AppModelContainer.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(notifications)
                .task { notifications.activate() }
        }
        .modelContainer(container)
    }
}
