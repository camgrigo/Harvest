import XCTest
import UserNotifications
@testable import Harvest

/// Pure logic for polite reminders: quiet-hours detection/shifting and interruption levels.
final class NotificationPolicyTests: XCTestCase {

    private let cal = Calendar(identifier: .gregorian)
    private func dateAt(_ hour: Int, day: Int = 9) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 6, day: day, hour: hour))!
    }

    // MARK: Quiet hours — overnight window (21→8)

    func testInQuietHoursOvernight() {
        var p = NotificationPolicy(); p.quietHoursEnabled = true
        p.quietHoursStart = 21; p.quietHoursEnd = 8
        XCTAssertTrue(p.isInQuietHours(dateAt(22), calendar: cal))
        XCTAssertTrue(p.isInQuietHours(dateAt(0), calendar: cal))
        XCTAssertTrue(p.isInQuietHours(dateAt(7), calendar: cal))
    }

    func testOutsideQuietHoursOvernight() {
        var p = NotificationPolicy(); p.quietHoursEnabled = true
        p.quietHoursStart = 21; p.quietHoursEnd = 8
        XCTAssertFalse(p.isInQuietHours(dateAt(9), calendar: cal))
        XCTAssertFalse(p.isInQuietHours(dateAt(12), calendar: cal))
        XCTAssertFalse(p.isInQuietHours(dateAt(20), calendar: cal))
    }

    func testQuietHoursDisabledIsAlwaysFalse() {
        var p = NotificationPolicy(); p.quietHoursEnabled = false
        p.quietHoursStart = 21; p.quietHoursEnd = 8
        XCTAssertFalse(p.isInQuietHours(dateAt(2), calendar: cal))
    }

    // MARK: Quiet hours — same-day window (10→15)

    func testSameDayQuietWindow() {
        var p = NotificationPolicy(); p.quietHoursEnabled = true
        p.quietHoursStart = 10; p.quietHoursEnd = 15
        XCTAssertTrue(p.isInQuietHours(dateAt(10), calendar: cal))
        XCTAssertTrue(p.isInQuietHours(dateAt(14), calendar: cal))
        XCTAssertFalse(p.isInQuietHours(dateAt(9), calendar: cal))
        XCTAssertFalse(p.isInQuietHours(dateAt(15), calendar: cal))
    }

    // MARK: Shifting

    func testShiftEarlyMorningToWindowEndSameDay() {
        var p = NotificationPolicy(); p.quietHoursEnabled = true
        p.quietHoursStart = 21; p.quietHoursEnd = 8
        let shifted = p.shiftOutOfQuietHours(dateAt(2), calendar: cal)  // 2 AM → 8 AM same day
        XCTAssertEqual(cal.component(.hour, from: shifted), 8)
        XCTAssertEqual(cal.component(.day, from: shifted), 9)
    }

    func testShiftEveningToNextMorning() {
        var p = NotificationPolicy(); p.quietHoursEnabled = true
        p.quietHoursStart = 21; p.quietHoursEnd = 8
        let shifted = p.shiftOutOfQuietHours(dateAt(22), calendar: cal)  // 10 PM → 8 AM next day
        XCTAssertEqual(cal.component(.hour, from: shifted), 8)
        XCTAssertEqual(cal.component(.day, from: shifted), 10)
    }

    func testNoShiftWhenOutsideQuietHours() {
        var p = NotificationPolicy(); p.quietHoursEnabled = true
        p.quietHoursStart = 21; p.quietHoursEnd = 8
        let noon = dateAt(12)
        XCTAssertEqual(p.shiftOutOfQuietHours(noon, calendar: cal), noon)
    }

    // MARK: Interruption levels

    func testTimeSensitiveWhenOverdueOrImminent() {
        let p = NotificationPolicy()
        let now = dateAt(12)
        XCTAssertEqual(p.interruptionLevel(for: dateAt(11), now: now), .timeSensitive)  // overdue
        let halfHour = now.addingTimeInterval(30 * 60)
        XCTAssertEqual(p.interruptionLevel(for: halfHour, now: now), .timeSensitive)
    }

    func testActiveWithinADay() {
        let p = NotificationPolicy()
        let now = dateAt(12)
        let inFiveHours = now.addingTimeInterval(5 * 3600)
        XCTAssertEqual(p.interruptionLevel(for: inFiveHours, now: now), .active)
    }

    func testPassiveBeyondADay() {
        let p = NotificationPolicy()
        let now = dateAt(12)
        let inThreeDays = now.addingTimeInterval(3 * 24 * 3600)
        XCTAssertEqual(p.interruptionLevel(for: inThreeDays, now: now), .passive)
    }

    // MARK: Persistence round-trip

    func testStoreRoundTrip() {
        let defaults = UserDefaults(suiteName: "NotificationPolicyTests")!
        defaults.removePersistentDomain(forName: "NotificationPolicyTests")
        var p = NotificationPolicy()
        p.remindersEnabled = false
        p.quietHoursEnabled = true
        p.quietHoursStart = 23
        NotificationPolicyStore.save(p, to: defaults)
        XCTAssertEqual(NotificationPolicyStore.load(from: defaults), p)
    }

    func testLoadDefaultWhenEmpty() {
        let defaults = UserDefaults(suiteName: "NotificationPolicyTests.empty")!
        defaults.removePersistentDomain(forName: "NotificationPolicyTests.empty")
        XCTAssertEqual(NotificationPolicyStore.load(from: defaults), .default)
    }
}
