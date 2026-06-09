import Foundation
import FoundationModels

/// Wraps the on-device language model. Two jobs: parse a free-text message into a
/// `ParsedMessage`, and write short summaries. Everything runs locally; when Apple
/// Intelligence is unavailable it transparently falls back to `FallbackParser`.
@MainActor
final class Assistant {

    // MARK: Availability

    static var isModelAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// In UI tests, force the deterministic offline parser so end-to-end flows don't hinge on the
    /// model's (non-deterministic) output — paralleling the in-memory store the harness already uses.
    static let isUITesting = ProcessInfo.processInfo.arguments.contains("-uitesting")

    /// A friendly explanation when the model can't run, or nil when it can.
    static var unavailabilityReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This device doesn't support Apple Intelligence, so I'll keep simple notes without smart summaries."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in Settings to unlock smart summaries. I'll still file your notes."
        case .unavailable(.modelNotReady):
            return "The on-device model is still getting ready. I'll keep simple notes meanwhile."
        case .unavailable:
            return "On-device intelligence is unavailable right now. I'll keep simple notes."
        @unknown default:
            return nil
        }
    }

    /// True when the reason is something the user can fix in Settings (Apple Intelligence off).
    static var unavailabilityActionable: Bool {
        if case .unavailable(.appleIntelligenceNotEnabled) = SystemLanguageModel.default.availability {
            return true
        }
        return false
    }

    // MARK: Publication reference

    /// A short reference of common jw.org publications and their abbreviations, injected into the
    /// model prompts so it recognises things like "ELF" (Enjoy Life Forever!) and never invents
    /// or assumes non-jw.org titles.
    static let publicationGuide = """
    Any publication, brochure, tract, video, or book mentioned is ALWAYS a jw.org publication — \
    never substitute or invent a secular or other-publisher title. Recognise these common ones and \
    their abbreviations (case-insensitive):
    - "Enjoy Life Forever!" brochure (ELF, lff) — the main Bible-study lessons/curriculum.
    - The Watchtower (w, WT) and Awake! (g) — the magazines.
    - "What Can the Bible Teach Us?" (bhs) and "What Does the Bible Really Teach?" (bh) — study books.
    - "Good News From God!" (fg), "Listen to God and Live Forever" (ll), "Listen to God" (ld) brochures.
    - "Was Life Created?" (lc) and "The Origin of Life—Five Questions Worth Asking" (lf) brochures.
    - "Where Can We Find Answers to Life's Big Questions?" (lvs).
    - "Who Are Doing Jehovah's Will Today?" (jwl).
    - New World Translation of the Holy Scriptures (NWT) — the Bible.
    - The JW Library app, jw.org, the "Enjoy Life Forever!" / Bible-study videos, tracts, and \
    invitations; the Daily Text ("Examining the Scriptures Daily").
    When an abbreviation or title appears, treat it as the matching jw.org publication above; if you \
    are unsure, keep the user's exact wording rather than guessing a different title.
    """

    // MARK: Parsing

    func parse(_ text: String) async -> ParsedMessage {
        guard Self.isModelAvailable, !Self.isUITesting else { return FallbackParser.parse(text) }
        let session = LanguageModelSession(instructions: parsingInstructions())
        do {
            return try await session.respond(to: text, generating: ParsedMessage.self).content
        } catch {
            return FallbackParser.parse(text)
        }
    }

    private func parsingInstructions() -> String {
        let today = DateFormatter.ymd.string(from: .now)
        let weekday = Date.now.formatted(.dateTime.weekday(.wide))
        return """
        You help someone keep a return-visit notebook for their volunteer ministry. \
        Today is \(today) (\(weekday)). Read the user's message and extract the fields. \
        Resolve relative dates such as "Saturday", "tomorrow", or "in three days" into an \
        exact YYYY-MM-DD date based on today. If the user only jotted a note or asked a \
        question, pick the closest intent and leave any field you can't fill as an empty string. \
        Keep the note text faithful to the user's own words.

        \(Self.publicationGuide)
        """
    }

    // MARK: Summaries

    func summarize(name: String, entries: [JournalEntry]) async -> String {
        let log = transcript(of: entries)
        guard Self.isModelAvailable, !log.isEmpty else {
            return FallbackParser.summary(name: name, entries: entries)
        }
        let instructions = """
        You are recapping a return-visit notebook for \(name). Write a short, warm, practical \
        summary in 3–5 sentences: who they are, what has been discussed, how interested they \
        seem, and one concrete suggestion for the next visit. Be specific and avoid fluff.

        \(Self.publicationGuide)
        """
        let session = LanguageModelSession(instructions: instructions)
        do {
            return try await session.respond(to: "Notes:\n\(log)").content
        } catch {
            return FallbackParser.summary(name: name, entries: entries)
        }
    }

    /// A grouped briefing of everyone due, one short paragraph per person with a next step.
    func weeklyBriefing(_ people: [(name: String, due: Date, entries: [JournalEntry])]) async -> String {
        let blocks = people.map { person -> String in
            let when = person.due.formatted(.dateTime.weekday(.wide).month().day())
            return "## \(person.name) (due \(when))\n\(transcript(of: person.entries))"
        }.joined(separator: "\n\n")

        guard Self.isModelAvailable, !blocks.isEmpty else {
            return FallbackParser.weeklyBriefing(people.map { ($0.name, $0.due, $0.entries) })
        }
        let instructions = """
        You are giving a short weekly briefing of the return visits that are due. For each person, \
        write one or two sentences: where things stand and a concrete next step. Keep their name as \
        a heading. Be warm, practical, and brief — this is a quick prep, not a report.

        \(Self.publicationGuide)
        """
        let session = LanguageModelSession(instructions: instructions)
        do {
            return try await session.respond(to: "People due:\n\(blocks)").content
        } catch {
            return FallbackParser.weeklyBriefing(people.map { ($0.name, $0.due, $0.entries) })
        }
    }

    /// A compact one-liner the chatbot keeps on a person for lists and map labels.
    func headline(name: String, entries: [JournalEntry]) async -> String {
        let log = transcript(of: entries)
        guard Self.isModelAvailable, !log.isEmpty else {
            return entries.last?.text.prefix(60).description ?? ""
        }
        let instructions = """
        In 8 words or fewer, capture the gist of where things stand with \(name). \
        No name, no period, no quotes — just the gist (e.g. "interested in why we suffer").

        \(Self.publicationGuide)
        """
        let session = LanguageModelSession(instructions: instructions)
        do {
            return try await session.respond(to: "Notes:\n\(log)").content
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return entries.last?.text.prefix(60).description ?? ""
        }
    }

    private func transcript(of entries: [JournalEntry]) -> String {
        entries
            .sorted { $0.date < $1.date }
            .map { "[\($0.date.formatted(date: .abbreviated, time: .omitted))] \($0.text)" }
            .joined(separator: "\n")
    }
}
