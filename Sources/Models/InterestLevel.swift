import Foundation

/// A light, optional status for a person. Never required to fill in —
/// the chatbot guesses it when it can, and you can change it on the detail screen.
enum InterestLevel: String, Codable, CaseIterable, Identifiable {
    case new
    case interested   // raw value kept for persistence; displayed as "None"
    case studying
    case paused

    var id: String { rawValue }

    var label: String {
        switch self {
        case .new:        "New"
        case .interested: "None"
        case .studying:   "Studying"
        case .paused:     "Paused"
        }
    }

    var symbol: String {
        switch self {
        case .new:        "leaf"
        case .interested: "circle"          // "None" — no status set
        case .studying:   "book.fill"
        case .paused:     "pause.circle.fill"
        }
    }
}
