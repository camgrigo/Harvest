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

/// Add a note to a person's page — finds them by name, or starts a page if they're new.
struct AddNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Add a Note"
    static let description = IntentDescription("Adds a note to a person's page in Harvest.")

    @Parameter(title: "Name", requestValueDialog: "Whose page is this note for?")
    var name: String

    @Parameter(title: "Note", requestValueDialog: "What's the note?")
    var note: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add a note to \(\.$name)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = AppModelContainer.shared.mainContext
        let person = NotebookEngine.findOrCreatePerson(
            named: name.trimmingCharacters(in: .whitespacesAndNewlines), context: context)
        context.insert(JournalEntry(text: note, person: person))
        try context.save()
        return .result(dialog: "Added a note to \(person.name).")
    }
}

/// Log a not-at-home (a door where no one answered) into your current territory.
struct LogNotAtHomeIntent: AppIntent {
    static let title: LocalizedStringResource = "Log a Not-at-Home"
    static let description = IntentDescription(
        "Records a door where no one answered, in your most recently worked territory.")

    @Parameter(title: "Address", requestValueDialog: "What's the address?")
    var address: String

    static var parameterSummary: some ParameterSummary {
        Summary("Log a not-at-home at \(\.$address)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = AppModelContainer.shared.mainContext
        let territory = Self.currentTerritory(in: context)
        let door = NotAtHome(address: address.trimmingCharacters(in: .whitespacesAndNewlines))
        context.insert(door)
        door.territory = territory
        territory.touch()
        try context.save()
        return .result(dialog: "Logged a not-at-home at \(door.address) in \(territory.name).")
    }

    /// The most recently worked territory, or a freshly created default one.
    @MainActor
    private static func currentTerritory(in context: ModelContext) -> Territory {
        let all = (try? context.fetch(FetchDescriptor<Territory>())) ?? []
        if let recent = all.max(by: {
            ($0.lastWorkedAt ?? $0.createdAt) < ($1.lastWorkedAt ?? $1.createdAt)
        }) {
            return recent
        }
        let territory = Territory(name: "My Territory")
        context.insert(territory)
        return territory
    }
}

/// Start a new house-to-house territory.
struct StartTerritoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a Territory"
    static let description = IntentDescription("Creates a new house-to-house territory in Harvest.")

    @Parameter(title: "Name", requestValueDialog: "What should the territory be called?")
    var name: String

    static var parameterSummary: some ParameterSummary {
        Summary("Start a territory called \(\.$name)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = AppModelContainer.shared.mainContext
        let territory = Territory(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        context.insert(territory)
        try context.save()
        return .result(dialog: "Started the territory \(territory.name).")
    }
}

/// Back up Harvest on demand from Siri / Shortcuts — writes an encrypted backup to iCloud Drive
/// and confirms. Uses the passphrase saved in Settings if there is one, or one passed in.
struct BackupHarvestIntent: AppIntent {
    static let title: LocalizedStringResource = "Back up Harvest"
    static let description = IntentDescription(
        "Creates an encrypted backup of your Harvest data to iCloud Drive.")

    @Parameter(title: "Passphrase", requestValueDialog: "Enter your backup passphrase")
    var passphrase: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Back up Harvest")
    }

    enum IntentError: LocalizedError {
        case missingPassphrase
        var errorDescription: String? {
            switch self {
            case .missingPassphrase: "No backup passphrase is set. Add one in Harvest's Backup settings first."
            }
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let phrase = passphrase?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? BackupService.autoBackupPassphrase()
        guard let phrase, !phrase.isEmpty else { throw IntentError.missingPassphrase }
        let context = AppModelContainer.shared.mainContext
        try BackupService.autoBackupToiCloud(context: context, passphrase: phrase)
        return .result(dialog: "Backup complete. Your data is now in iCloud Drive.")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Hands-free visit logging — "Log a visit in Harvest" then dictate the whole note. The on-device
/// language model parses it and files it (creating the person / entry / reminder as needed), then
/// Siri speaks the chatbot's confirmation back.
struct LogVisitBySpeechIntent: AppIntent {
    static let title: LocalizedStringResource = "Log a Visit by Speech"
    static let description = IntentDescription(
        "Dictate a visit note aloud — Harvest parses and files it, then speaks a confirmation.")

    @Parameter(title: "Visit Note", requestValueDialog: "What would you like to log?")
    var spokenNote: String

    static var parameterSummary: some ParameterSummary {
        Summary("Log a visit: \(\.$spokenNote)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = AppModelContainer.shared.mainContext
        let assistant = Assistant()
        let text = spokenNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = await assistant.parse(text)
        let reply = await NotebookEngine.apply(parsed, original: text, assistant: assistant, context: context)
        context.saveIfPossible()
        return .result(dialog: IntentDialog(stringLiteral: reply))
    }
}

/// Start a service session hands-free — "Start a service session in Harvest". Optionally names the
/// territory (found or created). Wire a Shortcuts "Arrive" location automation to this for
/// auto-start on arrival (see SHORTCUTS_GUIDE.md).
struct StartServiceSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Service Session"
    static let description = IntentDescription("Begins tracking a service session (hands-free).")

    @Parameter(title: "Territory")
    var territory: String?

    @Parameter(title: "Notes")
    var notes: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Start a service session")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = AppModelContainer.shared.mainContext

        // Don't double-start: if one's already running, just confirm.
        let active = (try? context.fetch(
            FetchDescriptor<ServiceSession>(predicate: #Predicate { $0.endAt == nil && $0.deletedAt == nil })
        ))?.first
        if active != nil {
            return .result(dialog: "A session is already running.")
        }

        var foundTerritory: Territory?
        if let name = territory?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            let all = (try? context.fetch(FetchDescriptor<Territory>())) ?? []
            foundTerritory = all.first { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
            if foundTerritory == nil {
                let made = Territory(name: name)
                context.insert(made)
                foundTerritory = made
            }
            foundTerritory?.touch()
        }

        let session = ServiceSession(
            territory: foundTerritory,
            notes: notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        context.insert(session)
        try context.save()
        SessionActivityManager.startActivity(sessionStartedAt: session.startAt)

        let where_ = foundTerritory?.name ?? "service"
        return .result(dialog: "Started a \(where_) session.")
    }
}

/// Stop the running service session — "Stop my session in Harvest" — and hear the minutes logged.
struct StopServiceSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Service Session"
    static let description = IntentDescription("Ends the current service session.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = AppModelContainer.shared.mainContext
        let active = (try? context.fetch(
            FetchDescriptor<ServiceSession>(predicate: #Predicate { $0.endAt == nil && $0.deletedAt == nil })
        ))?.first
        guard let session = active else {
            return .result(dialog: "There's no active session right now.")
        }
        session.stop()
        try context.save()
        SessionActivityManager.endActivity()
        let mins = (session.durationSeconds ?? 0) / 60
        return .result(dialog: "Session stopped. \(mins) minute\(mins == 1 ? "" : "s") logged.")
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
        AppShortcut(
            intent: AddNoteIntent(),
            phrases: [
                "Add a note in \(.applicationName)",
                "Note a visit in \(.applicationName)"
            ],
            shortTitle: "Add a Note",
            systemImageName: "note.text.badge.plus"
        )
        AppShortcut(
            intent: LogNotAtHomeIntent(),
            phrases: [
                "Log a not-at-home in \(.applicationName)",
                "No one answered in \(.applicationName)"
            ],
            shortTitle: "Log Not-at-Home",
            systemImageName: "door.left.hand.closed"
        )
        AppShortcut(
            intent: StartTerritoryIntent(),
            phrases: [
                "Start a territory in \(.applicationName)",
                "New territory in \(.applicationName)"
            ],
            shortTitle: "Start a Territory",
            systemImageName: "map"
        )
        AppShortcut(
            intent: BackupHarvestIntent(),
            phrases: [
                "Back up \(.applicationName)",
                "Backup \(.applicationName)",
                "Create a backup in \(.applicationName)"
            ],
            shortTitle: "Back up Harvest",
            systemImageName: "lock.doc.fill"
        )
        AppShortcut(
            intent: LogVisitBySpeechIntent(),
            phrases: [
                "Log a visit in \(.applicationName)",
                "File a visit in \(.applicationName)",
                "Record a visit in \(.applicationName)"
            ],
            shortTitle: "Log a Visit",
            systemImageName: "mic.badge.plus"
        )
        AppShortcut(
            intent: StartServiceSessionIntent(),
            phrases: [
                "Start a service session in \(.applicationName)",
                "Start ministry in \(.applicationName)",
                "Start my session in \(.applicationName)"
            ],
            shortTitle: "Start Session",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: StopServiceSessionIntent(),
            phrases: [
                "Stop my session in \(.applicationName)",
                "End service session in \(.applicationName)",
                "Stop ministry in \(.applicationName)"
            ],
            shortTitle: "Stop Session",
            systemImageName: "stop.circle"
        )
    }
}
