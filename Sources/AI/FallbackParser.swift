import Foundation

/// A lightweight, fully offline parser used when the on-device model isn't available.
/// It won't be as clever as the model, but it keeps the app working everywhere: it stores
/// your raw note and makes a reasonable guess at name, address, and a follow-up date.
enum FallbackParser {

    static func parse(_ text: String) -> ParsedMessage {
        let lower = text.lowercased()

        let asksRecap = lower.contains("summar") || lower.contains("recap")
            || lower.contains("catch me up") || lower.contains("brief")
        let aboutGroup = lower.contains("everyone") || lower.contains("this week")
            || lower.contains("due") || lower.contains("all of them")
        let asksAddress = lower.contains("address") || lower.contains("lives at")
            || lower.contains("lives on") || lower.contains("moved to")
            || lower.hasPrefix("find ") || lower.hasPrefix("look up ") || lower.hasPrefix("locate ")

        // An explicit edit: renaming, or changing interest with a change verb.
        let renameTo = detectRename(in: text)
        let interestGuess = detectInterest(in: lower)
        let changeVerb = lower.contains("change") || lower.contains("update")
            || lower.contains("correct") || lower.contains("mark") || lower.contains("rename")
            || lower.contains("set ") || lower.contains("no longer") || lower.contains("actually")
            || lower.contains(" now ")
        let isEdit = !renameTo.isEmpty || (interestGuess != .unknown && changeVerb)

        let intent: MessageIntent
        if asksRecap && aboutGroup {
            intent = .summarizeDue
        } else if asksRecap {
            intent = .summarizePerson
        } else if asksAddress {
            intent = .setAddress
        } else if lower.contains("who should i") || lower.contains("who do i")
                    || lower.contains("due") || lower.contains("this week") {
            intent = .listDue
        } else if isEdit {
            intent = .editPerson
        } else {
            intent = .logVisit
        }

        return ParsedMessage(
            intent: intent,
            personName: detectName(in: text),
            address: detectAddress(in: text),
            note: text,
            followUpDate: detectFollowUp(in: lower),
            interest: isEdit ? interestGuess : .unknown,
            newName: renameTo
        )
    }

    static func summary(name: String, entries: [JournalEntry]) -> String {
        guard !entries.isEmpty else {
            return "I don't have any notes on \(name) yet."
        }
        let count = entries.count
        let last = entries.sorted { $0.date < $1.date }.last!
        let when = last.date.formatted(date: .abbreviated, time: .omitted)
        return "\(name): \(count) note\(count == 1 ? "" : "s"). Most recent (\(when)): \(last.text)"
    }

    static func weeklyBriefing(_ people: [(name: String, due: Date, entries: [JournalEntry])]) -> String {
        people.map { person in
            let when = person.due.formatted(.dateTime.weekday(.abbreviated).month().day())
            let last = person.entries.sorted { $0.date < $1.date }.last?.text ?? "No notes yet."
            return "\(person.name) — due \(when)\n\(last)"
        }.joined(separator: "\n\n")
    }

    // MARK: Heuristics

    /// Looks for a capitalised word following a visit verb ("saw/met/visited/with/for Maria"),
    /// or a possessive ("Maria's address").
    private static func detectName(in text: String) -> String {
        let triggers = ["saw", "met", "visited", "with", "for", "called on", "talked to", "talked with",
                        "rename", "mark", "update", "change"]
        let words = text.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)

        // 1. Name right after a visit verb (most reliable for logged visits).
        for (i, word) in words.enumerated() {
            if triggers.contains(word.lowercased()), i + 1 < words.count {
                let candidate = stripPossessive(words[i + 1])
                if candidate.first?.isUppercase == true { return candidate }
            }
        }
        // 2. Possessive form like "Maria's".
        for word in words where word.hasSuffix("'s") || word.hasSuffix("’s") {
            let base = String(word.dropLast(2))
            if base.count > 1, base.first?.isUppercase == true { return base }
        }
        return ""
    }

    /// Drops a trailing possessive ("Maria's" → "Maria") so names stay clean.
    private static func stripPossessive(_ word: String) -> String {
        if word.hasSuffix("'s") || word.hasSuffix("’s") { return String(word.dropLast(2)) }
        return word
    }

    /// Pulls a corrected name out of a rename request like "rename Maria to Marie",
    /// "change Maria's name to Marie", or "her name is actually Marie".
    private static func detectRename(in text: String) -> String {
        let lower = text.lowercased()
        guard lower.contains("name") || lower.contains("rename")
            || lower.contains("call her") || lower.contains("call him")
            || lower.contains("spelled") || lower.contains("actually") else { return "" }

        let words = text.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        let connectors: Set<String> = ["to", "is", "actually", "called", "spelled", "be"]
        var result = ""
        for (i, word) in words.enumerated() where connectors.contains(word.lowercased()) {
            // Skip stacked connectors ("is actually Marie") to land on the new name.
            var j = i + 1
            while j < words.count, connectors.contains(words[j].lowercased()) { j += 1 }
            guard j < words.count else { continue }
            let candidate = words[j].trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            if candidate.first?.isUppercase == true { result = candidate }
        }
        return result
    }

    /// A coarse read of interest words, used only when the message is clearly an edit.
    private static func detectInterest(in lower: String) -> InterestGuess {
        if lower.contains("not interested") || lower.contains("no longer interested")
            || lower.contains("lost interest") || lower.contains("paused")
            || lower.contains("stopped") { return .paused }
        if lower.contains("studying") || lower.contains("a study")
            || lower.contains("bible study") { return .studying }
        if lower.contains("interested") || lower.contains("receptive") { return .interested }
        return .unknown
    }

    /// Looks for a number followed within a few words by a street-type word, and returns
    /// just "<number> … <streettype>" (stopping at the street type so trailing words are dropped).
    private static func detectAddress(in text: String) -> String {
        let streetTypes: Set<String> = ["st", "street", "ave", "avenue", "rd", "road", "blvd",
                                        "boulevard", "lane", "ln", "drive", "dr", "way", "court",
                                        "ct", "place", "pl", "terrace", "circle"]
        func clean(_ s: String) -> String {
            s.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:")).lowercased()
        }
        let tokens = text.split(separator: " ").map(String.init)
        for (i, token) in tokens.enumerated() where token.rangeOfCharacter(from: .decimalDigits) != nil {
            // Scan up to 3 words ahead for a street type; cut the address there.
            for offset in 1..<min(4, tokens.count - i) where streetTypes.contains(clean(tokens[i + offset])) {
                return tokens[i...(i + offset)]
                    .joined(separator: " ")
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
            }
        }
        return ""
    }

    /// Resolves a few common phrasings into a YYYY-MM-DD date.
    private static func detectFollowUp(in lower: String) -> String {
        let cal = Calendar.current
        func ymd(_ date: Date) -> String { DateFormatter.ymd.string(from: date) }

        if lower.contains("tomorrow") {
            return ymd(cal.date(byAdding: .day, value: 1, to: .now)!)
        }
        if let range = lower.range(of: #"in (\d+) days?"#, options: .regularExpression) {
            let digits = lower[range].filter(\.isNumber)
            if let n = Int(digits) {
                return ymd(cal.date(byAdding: .day, value: n, to: .now)!)
            }
        }
        if lower.contains("next week") {
            return ymd(cal.date(byAdding: .day, value: 7, to: .now)!)
        }
        let weekdays = ["sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7]
        for (name, target) in weekdays where lower.contains(name) {
            let todayWeekday = cal.component(.weekday, from: .now)
            var delta = target - todayWeekday
            if delta <= 0 { delta += 7 }
            return ymd(cal.date(byAdding: .day, value: delta, to: .now)!)
        }
        return ""
    }
}
