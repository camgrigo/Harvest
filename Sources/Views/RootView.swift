import SwiftUI
import SwiftData

/// The app's single root screen: the map + people/territories sheet (`ExploreView`). The old
/// tab bar is gone — house-to-house now lives in the same feed as territories. This thin wrapper
/// keeps the cross-cutting concerns: first-run onboarding, reminder-notification routing, and a
/// one-time migration that files legacy not-at-homes under a default territory.
struct RootView: View {
    @EnvironmentObject private var notifications: NotificationCoordinator
    @Environment(\.modelContext) private var context
    @AppStorage("hasOnboarded") private var hasOnboarded = false

    @State private var routedPerson: Person?

    private var isUITesting: Bool { ProcessInfo.processInfo.arguments.contains("-uitesting") }

    var body: some View {
        ExploreView()
            .fullScreenCover(isPresented: Binding(
                get: { !hasOnboarded },
                set: { if !$0 { hasOnboarded = true } }
            )) {
                OnboardingView {
                    hasOnboarded = true
                    // Ask for notification permission once onboarding is done — natural moment.
                    if !isUITesting { Task { await ReminderScheduler.shared.requestAuthorization() } }
                }
            }
            .task {
                // Returning users (already onboarded): ensure permission has been requested once.
                if hasOnboarded, !isUITesting { await ReminderScheduler.shared.requestAuthorization() }
            }
            .task { migrateOrphanDoors() }
            .task { backfillAttemptTimes() }
            .sheet(item: $routedPerson) { person in
                NavigationStack { PersonDetailView(person: person) }
            }
            .onChange(of: notifications.tappedPersonID) { _, id in
                openPerson(id)
            }
            .onChange(of: notifications.pendingAction) { _, action in
                applyAction(action)
            }
    }

    // MARK: Legacy data migration

    /// Files any not-at-homes that predate territories under a single default territory, so they
    /// stay reachable in the unified feed. Idempotent: only acts when orphans exist.
    private func migrateOrphanDoors() {
        guard let doors = try? context.fetch(FetchDescriptor<NotAtHome>()) else { return }
        let orphans = doors.filter { $0.territory == nil }
        guard !orphans.isEmpty else { return }

        let defaultName = "My Territory"
        let territory: Territory
        if let existing = try? context.fetch(
            FetchDescriptor<Territory>(predicate: #Predicate { $0.name == defaultName })
        ).first {
            territory = existing
        } else {
            territory = Territory(name: defaultName)
            context.insert(territory)
        }
        for door in orphans { door.territory = territory }
        context.saveIfPossible()
    }

    /// Seeds `attemptTimes` for doors created before time-of-day tracking, using the two timestamps
    /// we always had: createdAt and (if a distinct second knock) lastTriedAt. Idempotent — only
    /// touches rows whose attemptTimes is still empty.
    private func backfillAttemptTimes() {
        guard let doors = try? context.fetch(FetchDescriptor<NotAtHome>()) else { return }
        let stale = doors.filter { $0.attemptTimes.isEmpty }
        guard !stale.isEmpty else { return }

        for door in stale {
            var seed = [door.createdAt]
            if abs(door.lastTriedAt.timeIntervalSince(door.createdAt)) > 60 {
                seed.append(door.lastTriedAt)
            }
            door.attemptTimes = seed.sorted()
        }
        context.saveIfPossible()
    }

    // MARK: Notification routing

    /// Resolve a tapped reminder's person id and open their page.
    private func openPerson(_ id: UUID?) {
        guard let person = person(notifications.tappedPersonID) else { return }
        routedPerson = person
        notifications.tappedPersonID = nil
    }

    /// Apply a reminder action button ("Mark visited" / "Snooze") to the person.
    private func applyAction(_ action: NotificationCoordinator.ReminderAction?) {
        guard let action, let person = person(action.personID) else { return }
        switch action.kind {
        case .markVisited:
            person.nextVisitDate = nil
            ReminderScheduler.shared.cancel(id: person.id)
        case .snooze:
            let next = ReminderTime.morning(of: Calendar.current.date(
                byAdding: .day, value: ReminderScheduler.snoozeDays, to: .now)!)
            person.nextVisitDate = next
            ReminderScheduler.shared.schedule(id: person.id, name: person.name, on: next)
        }
        context.saveIfPossible()
        notifications.pendingAction = nil
    }

    private func person(_ id: UUID?) -> Person? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<Person>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
