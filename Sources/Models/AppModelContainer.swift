import SwiftData

/// Feature flags for capabilities that need entitlements not yet provisioned. All OFF by default.
enum FeatureFlags {
    /// CloudKit sync. Stays false until the CloudKit capability + container are enabled in Xcode.
    static let cloudKitEnabled = false
}

/// One shared SwiftData container for the whole app, reused by both the SwiftUI scene and the
/// App Intents that let Siri / Shortcuts add and query data. Sharing a single instance keeps the
/// running app and an intent in lockstep — no second store, no stale reads.
enum AppModelContainer {
    /// The on-disk container the app and its intents both use.
    static let shared: ModelContainer = make(inMemory: false)

    private static let schema = Schema([
        Person.self, JournalEntry.self, ChatMessage.self,
        NotAtHome.self, Territory.self, DoNotCall.self, ServicePlan.self,
        CongregationBoundary.self, ServiceSession.self,
        VisitLog.self,
    ])

    /// Builds a container for the app's models. `inMemory` backs UI-test launches with an
    /// ephemeral store so each run starts clean. `cloudKit` turns on CloudKit private-database
    /// sync — but ONLY if `FeatureFlags.cloudKitEnabled` is also true (it isn't yet; that needs the
    /// CloudKit entitlement). Until then this always builds the plain local store.
    static func make(inMemory: Bool, cloudKit: Bool = false) -> ModelContainer {
        do {
            let config: ModelConfiguration
            if cloudKit && FeatureFlags.cloudKitEnabled {
                config = ModelConfiguration(
                    schema: schema,
                    isStoredInMemoryOnly: inMemory,
                    cloudKitDatabase: .automatic)
            } else {
                config = ModelConfiguration(
                    schema: schema,
                    isStoredInMemoryOnly: inMemory,
                    cloudKitDatabase: .none)
            }
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Failed to create the notebook's storage: \(error)")
        }
    }
}
