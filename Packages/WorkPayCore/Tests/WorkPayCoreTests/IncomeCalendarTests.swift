import XCTest
@testable import WorkPayCore

final class IncomeCalendarTests: XCTestCase {
    let calendar = MainlandWorkCalendar.calendar
    func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value + "+08:00")! }

    func testCalendarSeparatesUnrecordedZeroPaidAndFutureDays() throws {
        let now = date("2026-10-02T12:00:00")
        let rule = PaySettings(effectiveFrom: date("2026-01-01T00:00:00"), monthlyBase: 0)
        let work = try PayEngine.attendance(on: now, settings: rule, deviceID: "phone", among: [])
        let result = PayEngine.incomeCalendar(inMonthOf: now, asOf: now, entries: [work], calendar: calendar)
        XCTAssertEqual(result.count, 31)
        XCTAssertFalse(result[0].hasRecords)
        XCTAssertTrue(result[1].hasRecords)
        XCTAssertEqual(result[1].summary.totalCents, 0)
        XCTAssertFalse(result[1].isFuture)
        XCTAssertTrue(result[2].isFuture)
    }
    func testCalendarUsesActualDailyEarningsAndSplitsOvernightOvertime() throws {
        let now = date("2026-10-03T12:00:00")
        let rule = PaySettings(effectiveFrom: date("2026-01-01T00:00:00"), monthlyBase: 7200, paidDays: 18)
        let daily = try PayEngine.attendance(on: date("2026-10-01T10:00:00"), settings: rule, deviceID: "phone", among: [])
        let overtime = WorkEntry(start: date("2026-10-01T23:00:00"), end: date("2026-10-02T01:00:00"), kind: .weekday, settings: rule, deviceID: "phone")
        let result = PayEngine.incomeCalendar(inMonthOf: now, asOf: now, entries: [daily, overtime], calendar: calendar)
        XCTAssertEqual(result[0].summary.regularCents, 40000)
        XCTAssertEqual(result[0].summary.overtimeCents, 7500)
        XCTAssertEqual(result[1].summary.overtimeCents, 7500)
        XCTAssertEqual(result.reduce(Int64(0)) { $0 + $1.summary.totalCents }, 55000)
        XCTAssertFalse(result[2].hasRecords)
    }
    func testLeapMonthAndConflictsAndDeletedRecords() {
        let now = date("2024-02-29T18:00:00")
        let rule = PaySettings(effectiveFrom: date("2024-01-01T00:00:00"), monthlyBase: 8000)
        let first = WorkEntry(start: date("2024-02-02T10:00:00"), end: date("2024-02-02T12:00:00"), kind: .weekday, settings: rule, deviceID: "phone")
        var second = first; second.id = UUID()
        var deleted = first; deleted.id = UUID(); deleted.start = date("2024-02-03T10:00:00"); deleted.end = deleted.start.addingTimeInterval(3600); deleted.deletedAt = now
        let result = PayEngine.incomeCalendar(inMonthOf: now, asOf: now, entries: [first, second, deleted], calendar: calendar)
        XCTAssertEqual(result.count, 29)
        XCTAssertTrue(result[1].hasConflict)
        XCTAssertTrue(result[1].hasRecords)
        XCTAssertEqual(result[1].summary.totalCents, 0)
        XCTAssertFalse(result[2].hasRecords)
    }
}
