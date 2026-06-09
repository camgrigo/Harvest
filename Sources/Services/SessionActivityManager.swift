import Foundation

#if canImport(ActivityKit)
import ActivityKit

/// Attributes passed to ActivityKit for a live service session. The matching Live Activity UI
/// lives in a Widget Extension target that must be added manually in Xcode (see project notes).
struct SessionActivityAttributes: ActivityAttributes {
    public typealias StatusUpdate = ContentState

    public struct ContentState: Codable, Hashable {
        var elapsedSeconds: Int
        var isActive: Bool
    }

    var sessionStartedAt: Date
}
#endif

/// Manages the Live Activity lifecycle for an active service session. Fully guarded: it no-ops
/// when ActivityKit is unavailable or Live Activities are disabled, so the app compiles and runs
/// without a Widget Extension target or any ActivityKit entitlement.
@MainActor
enum SessionActivityManager {

    #if canImport(ActivityKit)

    @available(iOS 16.1, *)
    private static var currentActivity: Activity<SessionActivityAttributes>? {
        get { _currentActivity as? Activity<SessionActivityAttributes> }
        set { _currentActivity = newValue }
    }
    /// Type-erased storage so the stored property itself carries no availability requirement.
    private static var _currentActivity: Any?

    /// Start a Live Activity for a new session.
    static func startActivity(sessionStartedAt: Date) {
        guard #available(iOS 16.1, *) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let attributes = SessionActivityAttributes(sessionStartedAt: sessionStartedAt)
        let initial = SessionActivityAttributes.ContentState(elapsedSeconds: 0, isActive: true)
        do {
            currentActivity = try Activity.request(
                attributes: attributes,
                content: .init(state: initial, staleDate: nil),
                pushType: nil
            )
        } catch {
            #if DEBUG
            print("⚠️ Failed to request Live Activity: \(error)")
            #endif
        }
    }

    /// Update the elapsed time in the current activity.
    static func updateActivity(elapsedSeconds: Int) {
        guard #available(iOS 16.1, *) else { return }
        let state = SessionActivityAttributes.ContentState(elapsedSeconds: elapsedSeconds, isActive: true)
        // Resolve the activity inside the Task so the non-Sendable value never crosses an
        // isolation boundary; only the Sendable content state is captured.
        Task { @MainActor in
            guard let activity = currentActivity else { return }
            nonisolated(unsafe) let act = activity
            await act.update(.init(state: state, staleDate: nil))
        }
    }

    /// End the current Live Activity.
    static func endActivity() {
        guard #available(iOS 16.1, *) else { return }
        let final = SessionActivityAttributes.ContentState(elapsedSeconds: 0, isActive: false)
        Task { @MainActor in
            guard let activity = currentActivity else { return }
            nonisolated(unsafe) let act = activity
            await act.end(.init(state: final, staleDate: nil), dismissalPolicy: .immediate)
            currentActivity = nil
        }
    }

    #else

    static func startActivity(sessionStartedAt: Date) {}
    static func updateActivity(elapsedSeconds: Int) {}
    static func endActivity() {}

    #endif
}
