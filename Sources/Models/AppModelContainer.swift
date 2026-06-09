import SwiftData

/// One shared SwiftData container for the whole app, reused by both the SwiftUI scene and the
/// App Intents that let Siri / Shortcuts add and query data. Sharing a single instance keeps the
/// running app and an intent in lockstep — no second store, no stale reads.
enum AppModelContainer {
    /// The on-disk container the app and its intents both use.
    static let shared: ModelContainer = make(inMemory: false)

    /// Builds a container for the app's models. `inMemory` backs UI-test launches with an
    /// ephemeral store so each run starts clean.
    static func make(inMemory: Bool) -> ModelContainer {
        do {
            return try ModelContainer(
                for: Person.self, JournalEntry.self, ChatMessage.self,
                     NotAtHome.self, Territory.self, DoNotCall.self, ServicePlan.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory)
            )
        } catch {
            fatalError("Failed to create the notebook's storage: \(error)")
        }
    }
}
