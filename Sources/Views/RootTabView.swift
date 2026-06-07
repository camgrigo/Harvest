import SwiftUI
import SwiftData

struct RootTabView: View {
    @EnvironmentObject private var notifications: NotificationCoordinator
    @Environment(\.modelContext) private var context
    @AppStorage("hasOnboarded") private var hasOnboarded = false

    @State private var selection = 1
    @State private var routedPerson: Person?

    private var isUITesting: Bool { ProcessInfo.processInfo.arguments.contains("-uitesting") }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Map", systemImage: "map.fill", value: 1) {
                ExploreView()
                    // Let the map extend beneath the glass tab bar.
                    .toolbarBackground(.hidden, for: .tabBar)
            }
            Tab("House to House", systemImage: "house.fill", value: 2) {
                NotAtHomeListView()
            }
        }
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
