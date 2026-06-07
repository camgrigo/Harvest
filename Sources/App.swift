import SwiftUI
import SwiftData

@main
struct ReturnVisitNotebookApp: App {
    let container: ModelContainer
    @StateObject private var notifications = NotificationCoordinator()

    init() {
        // UI tests pass "-uitesting" so each launch starts from a clean, ephemeral store.
        let uiTesting = ProcessInfo.processInfo.arguments.contains("-uitesting")
        do {
            container = try ModelContainer(
                for: Person.self, JournalEntry.self, ChatMessage.self, NotAtHome.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: uiTesting)
            )
        } catch {
            fatalError("Failed to create the notebook's storage: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(notifications)
                .task { notifications.activate() }
        }
        .modelContainer(container)
    }
}
