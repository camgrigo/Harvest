import Foundation

/// Pure formatting for sharing a territory's not-at-home and do-not-call lists. No UI or file I/O,
/// so it stays unit-testable and on-device.
enum NotAtHomeExporter {
    /// A human-readable plain-text summary for the share sheet.
    static func plainText(territory: Territory, asOf now: Date = .now) -> String {
        var lines = ["Territory: \(territory.name)"]

        if !territory.doNotCalls.isEmpty {
            lines.append("\nDo not call (\(territory.doNotCalls.count)):")
            lines.append(contentsOf: territory.sortedDoNotCalls.map { "• \($0.address)" })
        }

        if !territory.doors.isEmpty {
            lines.append("\nNot-at-homes (\(territory.doors.count)):")
            lines.append(contentsOf: territory.sortedDoors.map { door in
                "• \(door.address) (tried \(door.attemptCount)×, last "
                    + door.lastTriedAt.formatted(.dateTime.month().day().hour().minute()) + ")"
            })
        }

        if lines.count == 1 { lines.append("\nNo addresses logged yet.") }
        lines.append("\nExported: " + now.formatted(.dateTime.month().day().year().hour().minute()))
        return lines.joined(separator: "\n")
    }

    /// A spreadsheet-friendly CSV: address, type, attempt count, last-tried date.
    static func csv(territory: Territory) -> String {
        var lines = ["Address,Type,Attempts,Last Tried"]

        for door in territory.sortedDoors {
            let lastTried = door.lastTriedAt.formatted(.dateTime.month().day().year())
            lines.append("\(quoted(door.address)),Not-at-home,\(door.attemptCount),\(lastTried)")
        }
        for dnc in territory.sortedDoNotCalls {
            lines.append("\(quoted(dnc.address)),Do not call,0,")
        }
        return lines.joined(separator: "\n")
    }

    /// CSV-escape a field: wrap in quotes and double any embedded quotes.
    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
