import AppIntents
import SwiftData
import Foundation

/// Add a return visit by voice or from Shortcuts / Spotlight — e.g. "Add a return visit in Harvest".
/// iOS 27's system-wide Siri reaches the app through App Intents like this one, so this is the
/// chatbot-first front door for hands-free capture while you're at the door.
struct AddReturnVisitIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Return Visit"
    static let description = IntentDescription("Creates a new return visit in Harvest.")

    @Parameter(title: "Name", requestValueDialog: "Who did you meet?")
    var name: String

    @Parameter(title: "Note")
    var note: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Add a return visit for \(\.$name)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = AppModelContainer.shared.mainContext
        let person = Person(name: trimmedName.isEmpty ? name : trimmedName)
        if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            person.headline = note
        }
        context.insert(person)
        try context.save()
        return .result(dialog: "Added \(person.name) to your return visits.")
    }
}

/// Ask Harvest who needs a call back — "Who's due in Harvest" — and hear the list spoken back.
struct WhoIsDueIntent: AppIntent {
    static let title: LocalizedStringResource = "Who's Due"
    static let description = IntentDescription("Lists the return visits that are due today or overdue.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = AppModelContainer.shared.mainContext
        let descriptor = FetchDescriptor<Person>(
            predicate: #Predicate { !$0.isArchived },
            sortBy: [SortDescriptor(\.nextVisitDate)]
        )
        let due = ((try? context.fetch(descriptor)) ?? []).filter { $0.isDue }
        guard !due.isEmpty else {
            return .result(dialog: "Nothing's due right now.")
        }
        let names = due.map(\.name)
        let dialog: IntentDialog = names.count == 1
            ? "\(names[0]) is due for a return visit."
            : "\(names.count) return visits are due: \(names.formatted(.list(type: .and)))."
        return .result(dialog: dialog)
    }
}

/// Registers spoken phrases so Siri and Spotlight surface these with no setup from the user.
struct HarvestShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddReturnVisitIntent(),
            phrases: [
                "Add a return visit in \(.applicationName)",
                "New return visit in \(.applicationName)",
                "Log a return visit in \(.applicationName)"
            ],
            shortTitle: "Add Return Visit",
            systemImageName: "person.crop.circle.badge.plus"
        )
        AppShortcut(
            intent: WhoIsDueIntent(),
            phrases: [
                "Who's due in \(.applicationName)",
                "What's due in \(.applicationName)",
                "Show due return visits in \(.applicationName)"
            ],
            shortTitle: "Who's Due",
            systemImageName: "calendar.badge.clock"
        )
    }
}
