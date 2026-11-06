import XCTest
@testable import WorkPayCore

final class OvertimeBaseTests: XCTestCase {
    private var calendar: Calendar { MainlandWorkCalendar.calendar }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value + "+08:00")!
    }

    // Exercise the persisted/synced wire format, including older clients without this key.
    private func rule(overtimeBase: Decimal? = nil, paidDays: Decimal = 18,
                      dailyHours: Decimal = 8) throws -> PaySettings {
        let original = PaySettings(effectiveFrom: date("2026-01-01T00:00:00"), monthlyBase: 18000,
                                   paidDays: paidDays, dailyHours: dailyHours)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        if let overtimeBase { object["overtimeMonthlyBase"] = NSDecimalNumber(decimal: overtimeBase) }
        else { object.removeValue(forKey: "overtimeMonthlyBase") }
        return try JSONDecoder().decode(PaySettings.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func overtime(settings: PaySettings, kind: WorkKind = .weekday) -> WorkEntry {
        WorkEntry(start: date("2026-10-08T19:00:00"), end: date("2026-10-08T20:00:00"),
                  kind: kind, settings: settings, deviceID: "watch")
    }

    func testSeparateBaseAppliesToEveryOvertimeMultiplier() throws {
        let settings = try rule(overtimeBase: 7200)
        // 7,200 / 18 / 8 = 50 per hour, rather than the salary's 125.
        for (kind, expected) in [(WorkKind.weekday, Int64(7500)), (.weekend, 10000), (.holiday, 15000)] {
            let work = overtime(settings: settings, kind: kind)
            XCTAssertEqual(PayEngine.summary(on: work.start, asOf: work.end!, entries: [work], calendar: calendar).overtimeCents,
                           expected, kind.rawValue)
        }
    }

    func testSeparateBaseDoesNotChangeAttendanceOrLegacyRegularPay() throws {
        let settings = try rule(overtimeBase: 7200)
        let start = date("2026-10-08T09:00:00")
        let attendance = try PayEngine.attendance(on: start, settings: settings, deviceID: "phone", among: [])
        let work = overtime(settings: settings)
        let summary = PayEngine.summary(on: start, asOf: work.end!, entries: [attendance, work], calendar: calendar)
        XCTAssertEqual(summary.regularCents, 100000)
        XCTAssertEqual(summary.overtimeCents, 7500)
        let legacy = WorkEntry(start: start, end: start.addingTimeInterval(3600), kind: .regular,
                               settings: settings, deviceID: "phone")
        XCTAssertEqual(PayEngine.summary(on: start, asOf: legacy.end!, entries: [legacy], calendar: calendar).regularCents, 12500)
    }

    func testMonthlyEstimateAddsSeparateBaseOvertimeToFullSalary() throws {
        let settings = try rule(overtimeBase: 7200)
        let work = overtime(settings: settings)
        XCTAssertEqual(PayEngine.monthlyEstimate(on: work.start, settings: [settings], entries: [work],
                                                asOf: work.end!, calendar: calendar), 1807500)
    }

    func testMissingBasePreservesLegacyEarningsAndFollowsSalaryChanges() throws {
        var settings = try rule()
        let work = overtime(settings: settings)
        XCTAssertEqual(PayEngine.summary(on: work.start, asOf: work.end!, entries: [work], calendar: calendar).overtimeCents, 18750)
        settings.monthlyBase = 36000
        let changed = overtime(settings: settings)
        XCTAssertEqual(PayEngine.summary(on: changed.start, asOf: changed.end!, entries: [changed], calendar: calendar).overtimeCents, 37500)
        var data = PayData(); data.settings = [settings]; data.entries = [work]
        XCTAssertEqual(try PayDataCodec.decode(PayDataCodec.encode(data)), data)
    }

    func testExplicitZeroOrHigherBaseIsNotReplacedBySalary() throws {
        for (base, expected) in [(Decimal(0), Int64(0)), (36000, 37500)] {
            let settings = try rule(overtimeBase: base)
            XCTAssertNoThrow(try settings.validate())
            let work = overtime(settings: settings)
            XCTAssertEqual(PayEngine.summary(on: work.start, asOf: work.end!, entries: [work], calendar: calendar).overtimeCents, expected)
        }
    }

    func testSeparateBaseSurvivesPersistenceAndLaterSalaryChanges() throws {
        let original = try rule(overtimeBase: 7200)
        let work = overtime(settings: original)
        var updated = try rule(overtimeBase: 14400)
        updated.effectiveFrom = date("2026-10-09T00:00:00")
        updated.monthlyBase = 36000
        var data = PayData(); data.settings = [original, updated]; data.entries = [work]
        let restored = try PayDataCodec.decode(PayDataCodec.encode(data))
        let summary = PayEngine.summary(on: work.start, asOf: work.end!, entries: restored.entries, calendar: calendar)
        XCTAssertEqual(summary.overtimeCents, 7500)
        let newWork = overtime(settings: try XCTUnwrap(restored.settings.last))
        XCTAssertEqual(PayEngine.summary(on: newWork.start, asOf: newWork.end!, entries: [newWork], calendar: calendar).overtimeCents, 15000)
    }

    func testMidnightSplitKeepsIndependentBaseOnBothDays() throws {
        let work = WorkEntry(start: date("2026-10-08T23:00:00"), end: date("2026-10-09T01:00:00"),
                             kind: .weekend, settings: try rule(overtimeBase: 7200), deviceID: "watch")
        let pieces = PayEngine.splitAtMidnight(work, calendar: calendar)
        XCTAssertEqual(pieces.count, 2)
        for day in [work.start, date("2026-10-09T00:00:00")] {
            XCTAssertEqual(PayEngine.summary(on: day, asOf: work.end!, entries: pieces, calendar: calendar).overtimeCents, 10000)
        }
    }

    func testInvalidSeparateBaseIsRejectedBeforeStorage() throws {
        for base in [Decimal(-1), Decimal(1_000_000_000_001)] {
            let settings = try rule(overtimeBase: base)
            XCTAssertThrowsError(try settings.validate())
            var data = PayData(); data.settings = [settings]
            XCTAssertThrowsError(try PayDataCodec.encode(data))
        }
    }

    func testSeparateRateOverflowIsRejectedEvenWhenNormalSalaryIsZero() throws {
        var settings = try rule(overtimeBase: 1_000_000_000_000,
                                paidDays: Decimal(string: "0.1")!, dailyHours: 1)
        settings.monthlyBase = 0
        XCTAssertThrowsError(try settings.validate())
    }
}
