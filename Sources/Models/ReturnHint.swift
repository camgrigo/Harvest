import Foundation

/// Time-of-day buckets for "best time to return" hints.
enum TimeBucket: Int, CaseIterable, Sendable {
    case morning, afternoon, evening, night

    static func of(_ date: Date, calendar: Calendar = .current) -> TimeBucket {
        switch calendar.component(.hour, from: date) {
        case 5..<12:  .morning
        case 12..<17: .afternoon
        case 17..<21: .evening
        default:      .night
        }
    }

    var plural: String {
        switch self {
        case .morning: "mornings"
        case .afternoon: "afternoons"
        case .evening: "evenings"
        case .night: "nights"
        }
    }

    var single: String {
        switch self {
        case .morning: "morning"
        case .afternoon: "afternoon"
        case .evening: "evening"
        case .night: "evening"   // we never literally suggest "night"
        }
    }

    var symbol: String {
        switch self {
        case .morning: "sunrise"
        case .afternoon: "sun.max"
        case .evening: "sunset"
        case .night: "sunset"
        }
    }
}

/// A small value type that turns a door's knock history into a "try a different time" suggestion.
/// `text == nil` when there's nothing useful to say. `priority` drives the working-list sort
/// (higher = surface sooner). Sendable + deterministic (calendar injected) for testing.
struct ReturnHint: Sendable, Equatable {
    let text: String?
    let symbol: String
    let priority: Int

    init(times: [Date], calendar: Calendar = .current) {
        guard !times.isEmpty else {
            text = nil; symbol = "clock"; priority = 0
            return
        }

        var counts = [Int](repeating: 0, count: TimeBucket.allCases.count)
        for t in times { counts[TimeBucket.of(t, calendar: calendar).rawValue] += 1 }

        // Suggest the least-tried daytime bucket, preferring evening → afternoon → morning.
        // Night is counted but never suggested as a target.
        let candidates: [TimeBucket] = [.evening, .afternoon, .morning]
        var suggestion = candidates[0]
        for b in candidates where counts[b.rawValue] < counts[suggestion.rawValue] { suggestion = b }

        // The bucket you've tried most (for the "always tried X" phrasing).
        let dominant = TimeBucket.allCases.max { counts[$0.rawValue] < counts[$1.rawValue] } ?? .morning
        let distinctBuckets = counts.filter { $0 > 0 }.count
        let allSame = distinctBuckets == 1
        let dayGap = candidates.contains { counts[$0.rawValue] == 0 }

        if times.count == 1 {
            text = "Tried \(dominant.plural) — try \(suggestion.single)"
            symbol = suggestion.symbol
            priority = 1
        } else if allSame {
            text = "Always tried \(dominant.plural) — try \(suggestion.single)"
            symbol = suggestion.symbol
            priority = 3
        } else if dayGap {
            text = "Try \(suggestion.single) — not tried yet"
            symbol = suggestion.symbol
            priority = 2
        } else {
            text = "Try a different time"
            symbol = "clock.arrow.circlepath"
            priority = 1
        }
    }
}
