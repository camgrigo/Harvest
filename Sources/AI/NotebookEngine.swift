import Foundation
import SwiftData

/// Applies a parsed message to the notebook: finds or creates the person, files the note,
/// geocodes a new address, and sets the smart reminder. Returns the chatbot's reply text.
@MainActor
enum NotebookEngine {

    /// Default smart follow-up when a visit is logged but no date is given —
    /// a few days out, while the interest is still fresh (per jw.org guidance).
    static let freshInterestDays = 3

    static func apply(_ parsed: ParsedMessage,
                      original: String,
                      assistant: Assistant,
                      context: ModelContext) async -> String {
        switch parsed.intent {
        case .summarizePerson:
            guard let person = existingPerson(named: parsed.personName, context: context) else {
                return "I couldn't find anyone by that name yet. Tell me about a visit and I'll start a page for them."
            }
            return await assistant.summarize(name: person.name, entries: person.sortedEntries)

        case .listDue:
            return dueList(context: context)

        case .summarizeDue:
            let due = duePeople(context: context)
            guard !due.isEmpty else {
                return "Nobody's due in the next week — you're all caught up."
            }
            return await assistant.weeklyBriefing(
                due.map { ($0.person.name, $0.due, $0.person.sortedEntries) }
            )

        case .setAddress:
            return await setAddress(parsed, context: context)

        case .editPerson:
            return await editPerson(parsed, original: original, assistant: assistant, context: context)

        case .logVisit, .setReminder, .other:
            return await fileNote(parsed, original: original, assistant: assistant, context: context)
        }
    }

    /// The person a just-applied message created or changed (if any), so the chat can surface a
    /// tappable card for it. Resolved by name *after* `apply` has run — for a rename, by the new
    /// name. Query intents (due lists, summaries) have no single subject and return nil.
    static func subject(for parsed: ParsedMessage, context: ModelContext) -> Person? {
        switch parsed.intent {
        case .editPerson:
            let name = parsed.newName.isEmpty ? parsed.personName : parsed.newName
            return existingPerson(named: name, context: context)
        case .logVisit, .setReminder, .setAddress, .other:
            return existingPerson(named: parsed.personName, context: context)
        case .summarizePerson, .listDue, .summarizeDue:
            return nil
        }
    }

    // MARK: Searching / setting an address

    private static func setAddress(_ parsed: ParsedMessage, context: ModelContext) async -> String {
        let address = parsed.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            return "Tell me the address and I'll look it up — e.g. “Maria's address is 12 Oak Street, Springfield.”"
        }

        let coordinate = await AddressGeocoder.coordinate(for: address)
        let name = parsed.personName.trimmingCharacters(in: .whitespacesAndNewlines)

        // No person named: just report what the search found.
        guard !name.isEmpty else {
            if coordinate != nil {
                return "Found “\(address)”. Tell me whose place it is (e.g. “that's Maria's”) and I'll pin it, or touch and hold it on the map."
            }
            return "I couldn't find “\(address)” on the map. Try adding a city or more detail."
        }

        // Assign (and overwrite) the address on the named person.
        let person = findOrCreatePerson(named: name, context: context)
        person.addressText = address
        if let coordinate {
            person.latitude = coordinate.latitude
            person.longitude = coordinate.longitude
            return "Set \(person.name)'s address to \(address) and dropped a pin on the map."
        } else {
            person.latitude = nil
            person.longitude = nil
            return "Saved \(address) as \(person.name)'s address, but I couldn't place it on the map yet — try adding a city."
        }
    }

    // MARK: Editing an existing person

    /// Updates an existing person in place — name, interest, address, or reminder — without
    /// ever creating a new page. If we can't find who they mean, we ask rather than guess.
    private static func editPerson(_ parsed: ParsedMessage,
                                   original: String,
                                   assistant: Assistant,
                                   context: ModelContext) async -> String {
        let name = parsed.personName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return "Who would you like to update? Mention their name — e.g. “Change Maria's interest to studying.”"
        }
        guard let person = existingPerson(named: name, context: context) else {
            return "I don't have a page for \(name) yet. Tell me about a visit and I'll start one."
        }

        var changes: [String] = []

        // Rename / correct the name.
        let newName = parsed.newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !newName.isEmpty, newName.compare(person.name, options: .caseInsensitive) != .orderedSame {
            let old = person.name
            person.name = newName
            changes.append("renamed \(old) to \(newName)")
        }

        // Change interest level.
        if let level = parsed.interest.level, level != person.interest {
            person.interest = level
            changes.append("set interest to \(level.label.lowercased())")
        }

        // Update address → move the pin.
        let address = parsed.address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.isEmpty, address.compare(person.addressText, options: .caseInsensitive) != .orderedSame {
            person.addressText = address
            if let coord = await AddressGeocoder.coordinate(for: address) {
                person.latitude = coord.latitude
                person.longitude = coord.longitude
                changes.append("updated the address to \(address) and moved the pin")
            } else {
                person.latitude = nil
                person.longitude = nil
                changes.append("updated the address to \(address) (couldn't place it on the map yet)")
            }
        }

        // Reminder: clear it, or set a new date.
        let lower = original.lowercased()
        let clearsReminder = lower.contains("remind")
            && (lower.contains("remove") || lower.contains("clear") || lower.contains("cancel")
                || lower.contains("delete") || lower.contains("no more") || lower.contains("forget"))
        if clearsReminder {
            if person.nextVisitDate != nil {
                person.nextVisitDate = nil
                ReminderScheduler.shared.cancel(id: person.id)
                changes.append("cleared the reminder")
            }
        } else if let day = DateFormatter.ymd.date(from: parsed.followUpDate) {
            person.nextVisitDate = ReminderTime.morning(of: day)
            ReminderScheduler.shared.schedule(id: person.id, name: person.name, on: person.nextVisitDate!)
            let label = day.formatted(.dateTime.weekday(.abbreviated).month().day())
            changes.append("set the reminder to \(label)")
        }

        guard !changes.isEmpty else {
            return "I couldn't tell what to change for \(person.name). You can update their name, interest, address, or reminder."
        }
        return "Updated \(person.name): " + changes.joined(separator: "; ") + "."
    }

    // MARK: Filing a note

    private static func fileNote(_ parsed: ParsedMessage,
                                 original: String,
                                 assistant: Assistant,
                                 context: ModelContext) async -> String {
        let name = parsed.personName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return "Got it. Who was that about? Mention their name and I'll file it on their page."
        }

        let person = findOrCreatePerson(named: name, context: context)
        var parts: [String] = []
        let isNewPerson = person.entries.isEmpty && person.headline.isEmpty
        if isNewPerson { parts.append("Started a page for \(person.name).") }

        // Address → map pin.
        let address = parsed.address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.isEmpty {
            if person.addressText.isEmpty { person.addressText = address }
            if person.coordinate == nil {
                if let coord = await AddressGeocoder.coordinate(for: address) {
                    person.latitude = coord.latitude
                    person.longitude = coord.longitude
                    parts.append("📍 Dropped a pin at \(address).")
                } else {
                    parts.append("I saved “\(address)” but couldn't place it on the map yet — open \(person.name)'s page to add a city or adjust it.")
                }
            }
        }

        // The note itself (for a pure reminder change, there may be nothing to add).
        let noteText = parsed.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let entryText = noteText.isEmpty ? original : noteText
        if parsed.intent != .setReminder || !noteText.isEmpty {
            let entry = JournalEntry(text: entryText, person: person)
            context.insert(entry)
        }

        // Interest, only when the model is confident and we won't stomp a manual choice.
        if let level = parsed.interest.level, person.interest == .new {
            person.interest = level
        }

        // Reminder: explicit date if given, else a smart suggestion for a logged visit.
        let reminder = resolveReminderDate(parsed)
        if let day = reminder.date {
            person.nextVisitDate = ReminderTime.morning(of: day)
            ReminderScheduler.shared.schedule(id: person.id, name: person.name, on: person.nextVisitDate!)
            let label = day.formatted(.dateTime.weekday(.abbreviated).month().day())
            parts.append(reminder.wasSuggested
                         ? "I'll nudge you to go back around \(label) while the interest is fresh — just say a different day to change it."
                         : "I'll remind you to return on \(label).")
        }

        // Refresh the one-line gist used in lists and on the map.
        person.headline = await assistant.headline(name: person.name, entries: person.sortedEntries)

        if parts.isEmpty { parts.append("Filed it under \(person.name).") }
        return parts.joined(separator: " ")
    }

    private struct ResolvedReminder { var date: Date?; var wasSuggested: Bool }

    private static func resolveReminderDate(_ parsed: ParsedMessage) -> ResolvedReminder {
        if let explicit = DateFormatter.ymd.date(from: parsed.followUpDate) {
            return ResolvedReminder(date: explicit, wasSuggested: false)
        }
        if parsed.intent == .logVisit {
            let suggested = Calendar.current.date(byAdding: .day, value: freshInterestDays, to: .now)
            return ResolvedReminder(date: suggested, wasSuggested: true)
        }
        return ResolvedReminder(date: nil, wasSuggested: false)
    }

    // MARK: People lookup

    static func findOrCreatePerson(named name: String, context: ModelContext) -> Person {
        if let existing = existingPerson(named: name, context: context) {
            // Logging a fresh visit for someone you'd archived means they're back in view.
            if existing.isArchived { existing.isArchived = false }
            return existing
        }
        let person = Person(name: name)
        context.insert(person)
        return person
    }

    static func existingPerson(named name: String, context: ModelContext) -> Person? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let all = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        if let exact = all.first(where: { $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame }) {
            return exact
        }
        return all.first {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || trimmed.localizedCaseInsensitiveContains($0.name)
        }
    }

    // MARK: Who's due

    /// Everyone (not archived) with a reminder due within the next week or already overdue,
    /// soonest first. Shared by the quick list and the fuller weekly briefing.
    static func duePeople(context: ModelContext) -> [(person: Person, due: Date)] {
        let all = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        let horizon = Calendar.current.date(byAdding: .day, value: 7, to: .now)!
        return all
            .filter { !$0.isArchived }
            .compactMap { p in p.nextVisitDate.map { (person: p, due: $0) } }
            .filter { $0.due <= horizon }
            .sorted { $0.due < $1.due }
    }

    static func dueList(context: ModelContext) -> String {
        let upcoming = duePeople(context: context)
        guard !upcoming.isEmpty else {
            return "Nobody's due in the next week — you're all caught up."
        }
        let lines = upcoming.map { person, date -> String in
            let overdue = date < Calendar.current.startOfDay(for: .now)
            let label = date.formatted(.dateTime.weekday(.abbreviated).month().day())
            return "• \(person.name) — \(overdue ? "overdue (was \(label))" : "due \(label)")"
        }
        return "Here's who's coming up:\n" + lines.joined(separator: "\n")
    }
}
