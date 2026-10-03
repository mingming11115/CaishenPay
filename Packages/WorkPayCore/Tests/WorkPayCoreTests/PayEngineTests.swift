import XCTest
@testable import WorkPayCore

final class PayEngineTests: XCTestCase {
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: value + "+08:00")!
    }
    func settings(base: Decimal = 17400) -> PaySettings {
        PaySettings(effectiveFrom: date("2026-01-01T00:00:00"), monthlyBase: base)
    }
    func entry(_ start: String, _ end: String?, kind: WorkKind = .regular, settings rule: PaySettings? = nil) -> WorkEntry {
        WorkEntry(start: date(start), end: end.map(date), kind: kind,
                  settings: rule ?? settings(), deviceID: "phone", modifiedAt: date("2026-10-01T00:00:00"))
    }

    func testRegularPayClipsToShiftAndRemovesOnlyOverlappingLunch() {
        let work = entry("2026-10-01T08:00:00", "2026-10-01T20:00:00")
        let result = PayEngine.summary(on: work.start, asOf: date("2026-10-02T00:00:00"), entries: [work], calendar: calendar)
        XCTAssertEqual(result.regularSeconds, 8 * 3600)
        XCTAssertEqual(result.regularCents, 80000)
        XCTAssertEqual(result.overtimeCents, 0)
        let partial = entry("2026-10-01T12:30:00", "2026-10-01T14:00:00")
        XCTAssertEqual(PayEngine.summary(on: partial.start, asOf: date("2026-10-02T00:00:00"), entries: [partial], calendar: calendar).regularSeconds, 3600)
    }

    func testActiveRecordRestoresFromTimestampAndStopsAtNow() throws {
        let work = entry("2026-10-01T09:00:00", nil)
        let restored = try JSONDecoder().decode(WorkEntry.self, from: JSONEncoder().encode(work))
        let result = PayEngine.summary(on: work.start, asOf: date("2026-10-01T11:30:00"), entries: [restored], calendar: calendar)
        XCTAssertEqual(result.regularSeconds, 9000)
        XCTAssertEqual(result.regularCents, 25000)
    }

    func testOvertimeMultipliersAndZeroDuration() {
        for (kind, cents) in [(WorkKind.weekday, Int64(15000)), (.weekend, 20000), (.holiday, 30000)] {
            let work = entry("2026-10-01T19:00:00", "2026-10-01T20:00:00", kind: kind)
            XCTAssertEqual(PayEngine.summary(on: work.start, asOf: date("2026-10-02T00:00:00"), entries: [work], calendar: calendar).overtimeCents, cents)
        }
        let zero = entry("2026-10-01T09:00:00", "2026-10-01T09:00:00")
        XCTAssertEqual(PayEngine.summary(on: zero.start, asOf: zero.start, entries: [zero], calendar: calendar).totalCents, 0)
    }

    func testOvernightShiftAndAfterMidnightBreakAreClippedToCalendarDays() {
        var rule = settings()
        rule.startMinute = 22 * 60; rule.endMinute = 6 * 60
        rule.breakStartMinute = 2 * 60; rule.breakEndMinute = 3 * 60
        let work = entry("2026-10-01T21:00:00", "2026-10-02T07:00:00", settings: rule)
        let first = PayEngine.summary(on: work.start, asOf: date("2026-10-02T08:00:00"), entries: [work], calendar: calendar)
        let second = PayEngine.summary(on: date("2026-10-02T12:00:00"), asOf: date("2026-10-02T08:00:00"), entries: [work], calendar: calendar)
        XCTAssertEqual(first.regularSeconds, 7200)
        XCTAssertEqual(second.regularSeconds, 18000)
        XCTAssertEqual(first.regularCents + second.regularCents, 70000)
    }

    func testMidnightOvertimeSplitKeepsStableIDsAndSnapshot() {
        let work = entry("2026-10-01T23:00:00", "2026-10-03T01:00:00", kind: .weekend)
        let pieces = PayEngine.splitAtMidnight(work, calendar: calendar)
        XCTAssertEqual(pieces.count, 3)
        guard pieces.count == 3 else { return }
        XCTAssertEqual(pieces[0].id, work.id)
        XCTAssertEqual(Set(pieces.map(\.id)).count, 3)
        XCTAssertEqual(PayEngine.splitAtMidnight(work, calendar: calendar), pieces)
        XCTAssertEqual(pieces[0].end, date("2026-10-02T00:00:00"))
        XCTAssertEqual(pieces[1].end, date("2026-10-03T00:00:00"))
        XCTAssertFalse(pieces[0].needsTypeReview)
        XCTAssertTrue(pieces[1].needsTypeReview)
        XCTAssertTrue(pieces[2].needsTypeReview)
        XCTAssertTrue(pieces.allSatisfy { $0.settings == work.settings })
        let result = PayEngine.summary(on: work.start, asOf: date("2026-10-04T00:00:00"), entries: pieces, calendar: calendar)
        XCTAssertEqual(result.overtimeSeconds, 3600)
        XCTAssertEqual(result.overtimeCents, 20000)
    }

    func testOverlapRejectsAndExcludesEveryConflictingIDButAllowsTouchingBounds() {
        let first = entry("2026-10-01T09:00:00", "2026-10-01T11:00:00")
        let second = entry("2026-10-01T10:00:00", "2026-10-01T12:00:00", kind: .weekday)
        let touching = entry("2026-10-01T12:00:00", "2026-10-01T13:00:00", kind: .holiday)
        let now = date("2026-10-02T00:00:00")
        XCTAssertThrowsError(try PayEngine.validate(second, among: [first], asOf: now))
        XCTAssertNoThrow(try PayEngine.validate(touching, among: [first, second], asOf: now))
        XCTAssertEqual(PayEngine.conflictingIDs(in: [first, second, touching], asOf: now), Set([first.id, second.id]))
        let result = PayEngine.summary(on: first.start, asOf: now, entries: [first, second, touching], calendar: calendar)
        XCTAssertEqual(result.regularCents, 0)
        XCTAssertEqual(result.overtimeCents, 30000)
    }

    func testTwoActiveRecordsAtNowConflictAndOwnIDCanBeEdited() {
        let now = date("2026-10-01T10:00:00")
        let first = entry("2026-10-01T09:00:00", nil)
        let second = entry("2026-10-01T10:00:00", nil, kind: .weekday)
        XCTAssertThrowsError(try PayEngine.validate(second, among: [first], asOf: now))
        XCTAssertEqual(PayEngine.conflictingIDs(in: [first, second], asOf: now), Set([first.id, second.id]))
        var edit = first; edit.end = now
        XCTAssertNoThrow(try PayEngine.validate(edit, among: [first], asOf: now))
    }

    func testDeletedEntriesDoNotConflictOrCount() {
        var deleted = entry("2026-10-01T09:00:00", "2026-10-01T11:00:00")
        deleted.deletedAt = date("2026-10-02T00:00:00")
        let active = entry("2026-10-01T10:00:00", "2026-10-01T11:00:00", kind: .weekday)
        let result = PayEngine.summary(on: active.start, asOf: date("2026-10-02T00:00:00"), entries: [deleted, active], calendar: calendar)
        XCTAssertEqual(result.totalCents, 15000)
        XCTAssertTrue(PayEngine.conflictingIDs(in: [deleted, active], asOf: date("2026-10-02T00:00:00")).isEmpty)
    }

    func testEffectiveDatedSettingsDoNotRewriteHistoricalSnapshots() {
        let old = settings()
        var new = settings(base: 34800); new.effectiveFrom = date("2026-10-02T00:00:00")
        XCTAssertEqual(PayEngine.settings(on: date("2026-10-01T10:00:00"), in: [new, old]), old)
        XCTAssertEqual(PayEngine.settings(on: date("2026-10-02T10:00:00"), in: [old, new]), new)
        XCTAssertNil(PayEngine.settings(on: date("2025-12-01T00:00:00"), in: [old, new]))
        let work = entry("2026-10-01T19:00:00", "2026-10-01T20:00:00", kind: .weekday, settings: old)
        XCTAssertEqual(PayEngine.summary(on: work.start, asOf: date("2026-10-03T00:00:00"), entries: [work], calendar: calendar).overtimeCents, 15000)
    }

    func testMergeIsIdempotentCommutativeAndTombstoneWinsTies() {
        let original = entry("2026-10-01T09:00:00", "2026-10-01T10:00:00")
        var edit = original; edit.end = date("2026-10-01T11:00:00"); edit.modifiedAt = date("2026-10-02T00:00:00")
        XCTAssertEqual(PayEngine.mergedEntries(local: [edit], incoming: [original, edit]), [edit])
        var tie = edit; tie.kind = .weekend
        let forward = PayEngine.mergedEntries(local: [edit], incoming: [tie])
        XCTAssertEqual(forward, PayEngine.mergedEntries(local: [tie], incoming: [edit]))
        XCTAssertEqual(forward, PayEngine.mergedEntries(local: forward, incoming: [tie, original, edit]))
        var deleted = edit; deleted.deletedAt = edit.modifiedAt
        XCTAssertEqual(PayEngine.mergedEntries(local: [deleted], incoming: [edit]), [deleted])
        XCTAssertEqual(PayEngine.mergedEntries(local: [edit], incoming: [deleted]), [deleted])
    }

    func testMoneyUsesDecimalHalfUpRoundingWithoutIntegerOverflow() {
        XCTAssertEqual(PayEngine.cents(Decimal(string: "1.005")!), 101)
        XCTAssertEqual(PayEngine.cents(Decimal(string: "-1.005")!), -101)
        XCTAssertEqual(PayEngine.amount(cents: 29), Decimal(string: "0.29")!)
        XCTAssertEqual(PayEngine.cents(.nan), 0)
        XCTAssertEqual(PayEngine.cents(Decimal.greatestFiniteMagnitude), Int64.max)
    }

    func testSubCentFragmentsRoundOnlyAfterDailyAccumulation() {
        let first = entry("2026-10-01T19:00:00", "2026-10-01T19:00:01", kind: .weekday)
        let second = entry("2026-10-01T20:00:00", "2026-10-01T20:00:01", kind: .weekday)
        XCTAssertEqual(PayEngine.summary(on: first.start, asOf: date("2026-10-02T00:00:00"), entries: [first, second], calendar: calendar).overtimeCents, 8)
    }

    func testMonthlyEstimateUsesFullBasePlusOnlyThatMonthsOvertime() {
        let regular = entry("2026-10-01T09:00:00", "2026-10-01T18:00:00")
        let overtime = entry("2026-10-01T19:00:00", "2026-10-01T20:00:00", kind: .weekday)
        let crossing = entry("2026-09-30T23:00:00", "2026-10-01T01:00:00", kind: .weekend)
        XCTAssertEqual(PayEngine.monthlyEstimate(on: date("2026-10-01T00:00:00"), settings: [settings()], entries: [regular, overtime, crossing], asOf: date("2026-10-03T00:00:00"), calendar: calendar), 1775000)
    }

    func testValidationRejectsInvalidRatesDatesAndIntervals() {
        for value in [Decimal.zero, -1, .nan, Decimal.greatestFiniteMagnitude] {
            var rule = settings(); rule.paidDays = value
            XCTAssertThrowsError(try rule.validate())
        }
        var rule = settings(); rule.dailyHours = 0
        XCTAssertThrowsError(try rule.validate())
        rule = settings(); rule.monthlyBase = -1
        XCTAssertThrowsError(try rule.validate())
        rule = settings(); rule.weekdayMultiplier = -1
        XCTAssertThrowsError(try rule.validate())
        rule = settings(); rule.startMinute = 1440
        XCTAssertThrowsError(try rule.validate())
        rule = settings(); rule.timeZoneID = "invalid"
        XCTAssertThrowsError(try rule.validate())
        let invalid = entry("2026-10-01T11:00:00", "2026-10-01T10:00:00")
        XCTAssertThrowsError(try PayEngine.validate(invalid, among: [], asOf: date("2026-10-02T00:00:00")))
        let future = entry("2026-10-03T09:00:00", nil)
        XCTAssertThrowsError(try PayEngine.validate(future, among: [], asOf: date("2026-10-02T00:00:00")))
        XCTAssertNoThrow(try settings().validate())
    }

    func testLedgerPartialCrossMonthPaymentsAndOverpayment() {
        var month = SalaryMonth(id: "2026-09", expectedCents: 30,
                                payments: [SalaryPayment(amountCents: 10, paidAt: date("2026-10-01T00:00:00"))])
        XCTAssertEqual(month.receivedCents, 10)
        XCTAssertEqual(month.outstandingCents, 20)
        month.payments.append(SalaryPayment(amountCents: 20, paidAt: date("2026-11-01T00:00:00")))
        XCTAssertEqual(month.outstandingCents, 0)
        XCTAssertEqual(month.overpaidCents, 0)
        month.payments.append(SalaryPayment(amountCents: 5, paidAt: date("2026-11-02T00:00:00")))
        XCTAssertEqual(month.outstandingCents, 0)
        XCTAssertEqual(month.overpaidCents, 5)
    }

    func testUntrustedLedgerValuesNeverOverflow() {
        let month = SalaryMonth(id: "2026-10", expectedCents: Int64.max,
                                payments: [SalaryPayment(amountCents: Int64.max, paidAt: Date()),
                                           SalaryPayment(amountCents: Int64.max, paidAt: Date())])
        XCTAssertEqual(month.receivedCents, Int64.max)
        XCTAssertEqual(month.outstandingCents, 0)
        XCTAssertEqual(month.overpaidCents, 0)
    }

    func testEmptyDataContainsNoFinancialSamples() throws {
        let data = PayData()
        XCTAssertTrue(data.settings.isEmpty)
        XCTAssertTrue(data.entries.isEmpty)
        XCTAssertTrue(data.salaryMonths.isEmpty)
        XCTAssertFalse(data.hasCompletedSetup)
        XCTAssertEqual(try JSONDecoder().decode(PayData.self, from: JSONEncoder().encode(data)), data)
    }

    func testAcknowledgementOnlyClearsExactPayloadAndPreservesSubsequentEdits() {
        let sent = entry("2026-10-01T09:00:00", nil)
        var later = sent; later.end = date("2026-10-01T10:00:00")
        later.modifiedAt = date("2026-10-02T00:00:00")
        XCTAssertTrue(PayEngine.pendingEntries(afterAcknowledging: [sent], acknowledged: [sent]).isEmpty)
        XCTAssertEqual(PayEngine.pendingEntries(afterAcknowledging: [later], acknowledged: [sent]), [later])
        var sameClock = sent; sameClock.kind = .holiday
        XCTAssertEqual(PayEngine.pendingEntries(afterAcknowledging: [sameClock], acknowledged: [sent]), [sameClock])
        var tombstone = later; tombstone.deletedAt = later.modifiedAt
        XCTAssertEqual(PayEngine.pendingEntries(afterAcknowledging: [tombstone], acknowledged: [later]), [tombstone])
    }

    func testLedgerValidationRejectsNegativeZeroDuplicateAndOverflowPayments() {
        for cents in [Int64(-1), 0, Int64.max] {
            XCTAssertThrowsError(try SalaryPayment(amountCents: cents, paidAt: Date()).validate())
        }
        let payment = SalaryPayment(amountCents: 30, paidAt: date("2026-10-01T00:00:00"))
        XCTAssertThrowsError(try SalaryMonth(id: "2026-13", expectedCents: 100).validate())
        XCTAssertThrowsError(try SalaryMonth(id: "2026-10", expectedCents: -1).validate())
        XCTAssertThrowsError(try SalaryMonth(id: "2026-10", expectedCents: 100, payments: [payment, payment]).validate())
        XCTAssertNoThrow(try SalaryMonth(id: "2026-10", expectedCents: 0, payments: [payment]).validate())
    }

    func testCodecRoundTripsFinancialSnapshotsAndRejectsCorruptionOrUnknownSchema() throws {
        var data = PayData()
        data.settings = [settings()]
        data.entries = [entry("2026-10-01T09:00:00", "2026-10-01T11:00:00")]
        data.salaryMonths = [SalaryMonth(id: "2026-09", expectedCents: 100,
                                        payments: [SalaryPayment(amountCents: 29, paidAt: date("2026-10-01T00:00:00"))])]
        data.hasCompletedSetup = true
        XCTAssertEqual(try PayDataCodec.decode(PayDataCodec.encode(data)), data)
        XCTAssertThrowsError(try PayDataCodec.decode(Data("not json".utf8)))
        data.schemaVersion = 2
        XCTAssertThrowsError(try PayDataCodec.decode(JSONEncoder().encode(data)))
    }

    func testCodecRefusesInvalidSaveWithoutOverwritingExistingFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("salary.json")
        var data = PayData(); data.settings = [settings()]
        try PayDataCodec.write(data, to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try PayDataCodec.read(from: url), data)
        var invalid = data; invalid.settings[0].dailyHours = 0
        XCTAssertThrowsError(try PayDataCodec.write(invalid, to: url))
        XCTAssertEqual(try PayDataCodec.read(from: url), data)
    }

    func testSnapshotTimeZoneStillControlsShiftWhenDisplayTimeZoneChanges() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let work = entry("2026-10-01T07:00:00", "2026-10-01T11:00:00")
        let result = PayEngine.summary(on: date("2026-10-01T12:00:00"), asOf: date("2026-10-02T12:00:00"), entries: [work], calendar: utc)
        XCTAssertEqual(result.regularSeconds, 7200)
        XCTAssertEqual(result.regularCents, 20000)
    }

    func testDaylightSavingTransitionUsesActualElapsedTimeAndCivilShiftBounds() {
        let parser = ISO8601DateFormatter()
        let start = parser.date(from: "2026-03-08T00:00:00-05:00")!
        let end = parser.date(from: "2026-03-08T08:00:00-04:00")!
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        var rule = settings(); rule.timeZoneID = "America/New_York"
        rule.startMinute = 0; rule.endMinute = 8 * 60
        rule.breakStartMinute = 0; rule.breakEndMinute = 0
        let work = WorkEntry(start: start, end: end, kind: .regular, settings: rule, deviceID: "phone")
        let result = PayEngine.summary(on: start, asOf: end, entries: [work], calendar: ny)
        XCTAssertEqual(result.regularSeconds, 7 * 3600)
        XCTAssertEqual(result.regularCents, 70000)
    }

    func testBreakCrossingMidnightIsSubtractedFromBothDates() {
        var rule = settings(); rule.startMinute = 22 * 60; rule.endMinute = 6 * 60
        rule.breakStartMinute = 23 * 60; rule.breakEndMinute = 60
        let work = entry("2026-10-01T22:00:00", "2026-10-02T06:00:00", settings: rule)
        let first = PayEngine.summary(on: work.start, asOf: work.end!, entries: [work], calendar: calendar)
        let second = PayEngine.summary(on: work.end!, asOf: work.end!, entries: [work], calendar: calendar)
        XCTAssertEqual(first.regularSeconds, 3600)
        XCTAssertEqual(second.regularSeconds, 18000)
    }

    func testForgottenRegularTimerCannotStartPayingTheNextDaysShift() {
        let work = entry("2026-10-01T09:00:00", nil)
        let nextDay = date("2026-10-02T10:00:00")
        let result = PayEngine.summary(on: nextDay, asOf: nextDay, entries: [work], calendar: calendar)
        XCTAssertEqual(result.regularSeconds, 0)
        XCTAssertEqual(result.regularCents, 0)
        XCTAssertEqual(PayEngine.summary(on: work.start, asOf: nextDay, entries: [work], calendar: calendar).regularCents, 80000)
    }

    func testForgottenOvernightTimerOnlyPaysTheOriginalNightShift() {
        var rule = settings(); rule.startMinute = 22 * 60; rule.endMinute = 6 * 60
        rule.breakStartMinute = 2 * 60; rule.breakEndMinute = 3 * 60
        let work = entry("2026-10-01T22:00:00", nil, settings: rule)
        let secondDay = date("2026-10-02T23:00:00")
        let thirdDay = date("2026-10-03T08:00:00")
        XCTAssertEqual(PayEngine.summary(on: secondDay, asOf: secondDay, entries: [work], calendar: calendar).regularSeconds, 18000)
        XCTAssertEqual(PayEngine.summary(on: thirdDay, asOf: thirdDay, entries: [work], calendar: calendar).regularCents, 0)
    }

    func testStoppingAndSplittingForgottenRegularTimerRetainsOriginalShift() {
        let work = entry("2026-10-01T08:00:00", "2026-10-03T10:00:00")
        let pieces = PayEngine.splitAtMidnight(work, calendar: calendar)
        XCTAssertEqual(pieces.count, 3)
        let secondDay = date("2026-10-02T12:00:00")
        let thirdDay = date("2026-10-03T12:00:00")
        XCTAssertEqual(PayEngine.summary(on: secondDay, asOf: thirdDay, entries: pieces, calendar: calendar).regularCents, 0)
        XCTAssertEqual(PayEngine.summary(on: thirdDay, asOf: thirdDay, entries: pieces, calendar: calendar).regularCents, 0)
        XCTAssertEqual(PayEngine.summary(on: work.start, asOf: thirdDay, entries: pieces, calendar: calendar).regularCents, 80000)
    }

    func testStoppingAndSplittingForgottenOvernightTimerPreservesItsFirstNight() {
        var rule = settings(); rule.startMinute = 22 * 60; rule.endMinute = 6 * 60
        rule.breakStartMinute = 2 * 60; rule.breakEndMinute = 3 * 60
        let work = entry("2026-10-01T21:00:00", "2026-10-03T08:00:00", settings: rule)
        let pieces = PayEngine.splitAtMidnight(work, calendar: calendar)
        let secondDay = date("2026-10-02T23:00:00")
        let thirdDay = date("2026-10-03T08:00:00")
        XCTAssertEqual(PayEngine.summary(on: work.start, asOf: thirdDay, entries: pieces, calendar: calendar).regularCents, 20000)
        XCTAssertEqual(PayEngine.summary(on: secondDay, asOf: thirdDay, entries: pieces, calendar: calendar).regularCents, 50000)
        XCTAssertEqual(PayEngine.summary(on: thirdDay, asOf: thirdDay, entries: pieces, calendar: calendar).regularCents, 0)
    }

    func testOriginalShiftAnchorSurvivesJSONAndLegacyRecordsWithoutItStillDecode() throws {
        let work = entry("2026-10-01T09:00:00", "2026-10-03T10:00:00")
        let pieces = PayEngine.splitAtMidnight(work, calendar: calendar)
        let restored = try JSONDecoder().decode([WorkEntry].self, from: JSONEncoder().encode(pieces))
        XCTAssertTrue(restored.allSatisfy { $0.regularShiftAnchor == date("2026-10-01T09:00:00") })
        XCTAssertEqual(PayEngine.summary(on: date("2026-10-02T12:00:00"), asOf: work.end!, entries: restored, calendar: calendar).regularCents, 0)
        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(work)) as? [String: Any])
        legacyObject.removeValue(forKey: "regularShiftAnchor")
        let legacy = try JSONDecoder().decode(WorkEntry.self, from: JSONSerialization.data(withJSONObject: legacyObject))
        XCTAssertNil(legacy.regularShiftAnchor)
        XCTAssertEqual(PayEngine.summary(on: date("2026-10-02T12:00:00"), asOf: work.end!, entries: [legacy], calendar: calendar).regularCents, 0)
    }
}
