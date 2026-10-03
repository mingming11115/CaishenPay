import XCTest
@testable import WorkPayCore

final class AttendanceTests: XCTestCase {
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value + "+08:00")!
    }
    // Ignoring the attendance snapshot would return zero for this zero-duration record.
    func attendance() throws -> WorkEntry {
        let now = date("2026-10-08T09:00:00")
        let rule = PaySettings(effectiveFrom: date("2026-01-01T00:00:00"), monthlyBase: 18000, dailyHours: 3)
        let record = WorkEntry(start: now, end: now, kind: .regular, settings: rule, deviceID: "phone")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        object["attendanceWorkdays"] = 18
        return try JSONDecoder().decode(WorkEntry.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testAttendancePaysFullDayImmediatelyWithoutHours() throws {
        let work = try attendance()
        let result = PayEngine.summary(on: work.start, asOf: work.start, entries: [work], calendar: calendar)
        XCTAssertEqual(result.regularCents, 100000)
        XCTAssertEqual(result.regularSeconds, 0)
        let later = PayEngine.summary(on: work.start, asOf: date("2026-10-08T22:00:00"), entries: [work], calendar: calendar)
        XCTAssertEqual(later, result)
    }
    func testDuplicateAttendanceDoesNotDoublePayAndDoesNotConflictWithOvertime() throws {
        let work = try attendance()
        var duplicate = work; duplicate.id = UUID()
        let overtime = WorkEntry(start: work.start, end: work.start.addingTimeInterval(3600), kind: .weekday,
                                 settings: work.settings, deviceID: "watch")
        let result = PayEngine.summary(on: work.start, asOf: overtime.end!, entries: [duplicate, work, overtime], calendar: calendar)
        XCTAssertEqual(result.regularCents, 100000)
        XCTAssertGreaterThan(result.overtimeCents, 0)
        XCTAssertTrue(PayEngine.conflictingIDs(in: [work, overtime], asOf: overtime.end!).isEmpty)
    }
    func testDeletedAndFutureAttendanceDoesNotPay() throws {
        var work = try attendance()
        XCTAssertEqual(PayEngine.summary(on: work.start, asOf: work.start.addingTimeInterval(-1), entries: [work], calendar: calendar).totalCents, 0)
        work.deletedAt = work.start
        XCTAssertEqual(PayEngine.summary(on: work.start, asOf: work.start, entries: [work], calendar: calendar).totalCents, 0)
    }
}

extension AttendanceTests {
    func testOfficialCalendarCountsHolidaysAndMakeupDays() throws {
        // October has 22 weekdays, minus five holiday weekdays, plus October 10.
        XCTAssertEqual(try MainlandWorkCalendar.workdays(inMonthOf: date("2026-10-01T00:00:00")), 18)
        XCTAssertEqual(try MainlandWorkCalendar.workdays(inMonthOf: date("2026-02-01T00:00:00")), 16)
        XCTAssertEqual(try MainlandWorkCalendar.workdays(inMonthOf: date("2026-09-01T00:00:00")), 22)
        XCTAssertTrue(try MainlandWorkCalendar.isWorkday(date("2026-10-10T09:00:00")))
        XCTAssertFalse(try MainlandWorkCalendar.isWorkday(date("2026-10-01T09:00:00")))
        XCTAssertFalse(try MainlandWorkCalendar.isWorkday(date("2026-10-11T09:00:00")))
        XCTAssertThrowsError(try MainlandWorkCalendar.workdays(inMonthOf: date("2027-01-01T00:00:00")))
    }
    func testAttendanceFactoryUsesDateMonthAndRejectsDuplicates() throws {
        let rule = PaySettings(effectiveFrom: date("2026-01-01T00:00:00"), monthlyBase: 18000)
        let now = date("2026-10-08T09:00:00")
        let entry = try PayEngine.attendance(on: now, settings: rule, deviceID: "phone", among: [])
        XCTAssertEqual(entry.attendanceWorkdays, 18)
        XCTAssertEqual(entry.end, entry.start)
        XCTAssertThrowsError(try PayEngine.attendance(on: now.addingTimeInterval(3600), settings: rule, deviceID: "phone", among: [entry]))
        XCTAssertNoThrow(try PayEngine.validate(entry, among: [], asOf: now))
        let restored = try JSONDecoder().decode(WorkEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(restored, entry)
    }
}

extension AttendanceTests {
    func testLegacyEditCannotAddHourlyPayToAttendanceDay() throws {
        let daily = try attendance()
        let legacy = WorkEntry(start: date("2026-10-08T14:00:00"), end: date("2026-10-08T15:00:00"),
                               kind: .regular, settings: daily.settings, deviceID: "phone")
        let now = date("2026-10-08T22:00:00")
        XCTAssertThrowsError(try PayEngine.validate(legacy, among: [daily], asOf: now))
        // Mixed records received from an older device must be flagged, never double-paid.
        XCTAssertEqual(PayEngine.conflictingIDs(in: [daily, legacy], asOf: now), Set([daily.id, legacy.id]))
        XCTAssertEqual(PayEngine.summary(on: daily.start, asOf: now, entries: [daily, legacy], calendar: calendar).regularCents, 0)
    }
    func testAttendanceSnapshotsItsMonthForLaterOvertimeConversion() throws {
        let rule = PaySettings(effectiveFrom: date("2026-09-01T00:00:00"), monthlyBase: 18000, paidDays: 22)
        let entry = try PayEngine.attendance(on: date("2026-10-08T09:00:00"), settings: rule, deviceID: "phone", among: [])
        XCTAssertEqual(entry.settings.paidDays, 18)
        XCTAssertEqual(entry.settings.hourlyRate, 125)
    }
}

extension AttendanceTests {
    func testAttendanceStatusDistinguishesLegacyTimersFromFullDays() throws {
        let day = date("2026-10-08T09:00:00")
        let legacy = WorkEntry(start: day, end: day.addingTimeInterval(60), kind: .regular,
                               settings: PaySettings(effectiveFrom: day, monthlyBase: 18000), deviceID: "phone")
        XCTAssertEqual(PayEngine.attendanceStatus(on: day, asOf: day.addingTimeInterval(3600), entries: [legacy]), .legacy)
        let daily = try attendance()
        XCTAssertEqual(PayEngine.attendanceStatus(on: day, asOf: day, entries: [daily]), .recorded)
        var deleted = daily; deleted.deletedAt = day
        XCTAssertEqual(PayEngine.attendanceStatus(on: day, asOf: day, entries: [deleted]), .none)
        XCTAssertEqual(PayEngine.attendanceStatus(on: day, asOf: day.addingTimeInterval(3600), entries: [daily, legacy]), .conflict)
        XCTAssertEqual(PayEngine.attendanceStatus(on: date("2026-10-09T09:00:00"), asOf: day, entries: [daily]), .none)
    }
    func testAttendanceSurvivesDiskRoundTripWithItsOriginalDailyRate() throws {
        var work = try attendance()
        work.start = date("2026-09-08T09:00:00"); work.end = work.start
        var data = PayData(); data.settings = [work.settings]; data.hasCompletedSetup = true; data.entries = [work]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try PayDataCodec.write(data, to: file)
        let restored = try PayDataCodec.read(from: file)
        XCTAssertEqual(restored.entries, [work])
        XCTAssertEqual(PayEngine.summary(on: work.start, asOf: work.start, entries: restored.entries, calendar: calendar).regularCents, 100000)
    }
}

extension AttendanceTests {
    func testDateOnlyAttendanceIgnoresHiddenTimeButRejectsTomorrow() throws {
        let now = date("2026-10-08T09:00:00")
        XCTAssertEqual(try PayEngine.attendanceDate(date("2026-10-08T23:30:00"), asOf: now), date("2026-10-08T00:00:00"))
        XCTAssertThrowsError(try PayEngine.attendanceDate(date("2026-10-09T00:00:00"), asOf: now))
    }
    func testEditingAttendancePreservesSameMonthSnapshotAndRecalculatesNewMonth() throws {
        var previous = try attendance()
        previous.attendanceWorkdays = 20
        previous.settings.paidDays = 20
        let sameMonth = try PayEngine.attendance(on: date("2026-10-09T00:00:00"), settings: previous.settings,
            deviceID: "phone", among: [previous], replacing: previous)
        XCTAssertEqual(sameMonth.id, previous.id)
        XCTAssertEqual(sameMonth.attendanceWorkdays, 20)
        XCTAssertEqual(sameMonth.settings.paidDays, 20)
        let otherMonth = try PayEngine.attendance(on: date("2026-02-09T00:00:00"), settings: previous.settings,
            deviceID: "phone", among: [previous], replacing: previous)
        XCTAssertEqual(otherMonth.id, previous.id)
        XCTAssertEqual(otherMonth.attendanceWorkdays, 16)
        XCTAssertEqual(otherMonth.settings.paidDays, 16)
        XCTAssertEqual(otherMonth.settings.monthlyBase, previous.settings.monthlyBase)
    }
    func testLegacyConversionReplacesOriginalAndRejectsAnotherRegularEntry() throws {
        let start = date("2026-10-08T09:00:00")
        let settings = PaySettings(effectiveFrom: start, monthlyBase: 18000)
        let legacy = WorkEntry(start: start, end: start.addingTimeInterval(3600), kind: .regular, settings: settings, deviceID: "phone")
        let converted = try PayEngine.attendance(on: start, settings: settings, deviceID: "phone", among: [legacy], replacing: legacy)
        XCTAssertEqual(converted.id, legacy.id)
        XCTAssertEqual(converted.end, converted.start)
        XCTAssertEqual(converted.attendanceWorkdays, 18)
        var another = legacy; another.id = UUID()
        XCTAssertThrowsError(try PayEngine.attendance(on: start, settings: settings, deviceID: "phone", among: [legacy, another], replacing: legacy))
    }
}
