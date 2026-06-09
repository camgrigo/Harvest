import Foundation

extension DateFormatter {
    /// Strict machine date used to parse the model's `YYYY-MM-DD` output.
    static let ymd: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Filesystem-safe UTC timestamp for uniquely naming auto-backup files.
    static let isoDateTime: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(abbreviation: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HHmmss"
        return f
    }()
}

enum ReminderTime {
    /// Turns a calendar day into a concrete reminder moment (10am local that day).
    static func morning(of day: Date) -> Date {
        Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: day) ?? day
    }
}
