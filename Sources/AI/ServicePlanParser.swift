import Foundation

/// Offline natural-language parsing for a new service plan. Pulls a date+time, a meeting place, and
/// a partner out of a line like "Sat 9am at the Kingdom Hall with John, bring tracts", and hands
/// back whatever prose is left over as the note. Mirrors the spirit of `FallbackParser`, but tuned
/// for plans — it cares about *when / where / with*, not people and visits. Fully on-device.
enum ServicePlanParser {

    struct Parsed: Equatable {
        var date: Date?
        var place: String
        var partner: String
        /// The original text with the recognized when/where/with fragments removed — used as the note.
        var note: String
    }

    static func parse(_ text: String) -> Parsed {
        var working = text
        let date = extractDate(&working)
        // Partner first ("with …"), then place ("at …"), so each removal narrows what's left.
        let partner = extractPhrase(&working,
                                    prepositions: ["alongside", "with"],
                                    stops: ["\\bat\\b", "\\bmeet\\b", "\\bmeeting\\b",
                                            "\\bby\\b", "\\boutside\\b", "\\bfrom\\b"])
        let place = extractPhrase(&working,
                                  prepositions: ["meeting at", "meet at", "meet by", "meeting",
                                                 "outside", "from", "at", "by"],
                                  stops: ["\\bwith\\b", "\\balongside\\b", "\\band\\b"],
                                  rejectingBareTime: true)
        return Parsed(date: date, place: place, partner: partner, note: tidy(working))
    }

    // MARK: Date + time

    /// Detects the first date/time with `NSDataDetector`, removes it from `text`, and returns it.
    /// When a day is given without a clock time (the detector lands on midnight), defaults to 9 AM —
    /// a sensible field-service start — so the picker isn't stuck at 12:00 AM.
    private static func extractDate(_ text: inout String) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector.matches(in: text, range: range).first,
              var date = match.date,
              let swiftRange = Range(match.range, in: text) else { return nil }

        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: date)
        if (comps.hour ?? 0) == 0 && (comps.minute ?? 0) == 0 {
            date = cal.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date
        }
        text.removeSubrange(swiftRange)
        return date
    }

    // MARK: Place / partner

    /// Captures the words after the first matching preposition (e.g. "with <partner>", "at <place>")
    /// up to a comma, a competing keyword, or the end — then removes that whole fragment so the
    /// remaining prose can become the note. Longest prepositions are tried first ("meet at" > "at").
    private static func extractPhrase(_ text: inout String,
                                      prepositions: [String],
                                      stops: [String],
                                      rejectingBareTime: Bool = false) -> String {
        let alts = prepositions
            .sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        let stopAlt = (["," , "$"] + stops).joined(separator: "|")
        let pattern = "\\b(?:\(alts))\\b\\s+(.+?)(?=\(stopAlt))"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return ""
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = re.firstMatch(in: text, range: range),
              match.numberOfRanges >= 2,
              let valueRange = Range(match.range(at: 1), in: text),
              let fullRange = Range(match.range, in: text) else { return "" }

        let value = text[valueRange].trimmingCharacters(in: CharacterSet(charactersIn: " .,;:"))
        guard !value.isEmpty else { return "" }
        // A leftover time that the date detector split off ("...at 9am") isn't a place — leave it.
        if rejectingBareTime,
           value.range(of: #"^\d{1,2}(:\d{2})?\s*([ap]\.?m\.?)?$"#,
                       options: [.regularExpression, .caseInsensitive]) != nil {
            return ""
        }
        text.removeSubrange(fullRange)
        return value
    }

    // MARK: Tidy

    /// Cleans the leftover prose into a usable note: collapses whitespace, drops orphaned commas and
    /// dangling connector words left behind by the extractions, and trims the edges.
    private static func tidy(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: " ,", with: ",")
        s = s.replacingOccurrences(of: "(,\\s*){2,}", with: ", ", options: .regularExpression)
        // Trim leading punctuation, then a dangling leading connector ("and bring …", "to bring …").
        s = s.replacingOccurrences(of: "^[\\s,;:.–—-]+", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "^(and|then|to)\\b\\s*", with: "",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "[\\s,;:]+$", with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
