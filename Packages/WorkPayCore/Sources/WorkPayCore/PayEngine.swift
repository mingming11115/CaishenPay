import Foundation

public enum PayEngine {
    public static let maximumAmountCents: Int64 = 100_000_000_000_000

    /// An acknowledgement for an older revision must never erase an offline edit.
    public static func pendingEntries(afterAcknowledging pending: [WorkEntry], acknowledged: [WorkEntry]) -> [WorkEntry] {
        let acknowledgements = Dictionary(grouping: acknowledged, by: \.id)
        return pending.filter { !(acknowledgements[$0.id]?.contains($0) ?? false) }
    }

    /// Round at posting/display boundaries. Invalid inputs become zero; overflow saturates.
    /// Mutation validation rejects these values before storage.
    public static func cents(_ amount: Decimal) -> Int64 {
        guard !amount.isNaN else { return 0 }
        if amount >= Decimal(Int64.max) / 100 { return .max }
        if amount <= Decimal(Int64.min) / 100 { return .min }
        var scaled = amount * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return NSDecimalNumber(decimal: rounded).int64Value
    }

    public static func amount(cents: Int64) -> Decimal { Decimal(cents) / 100 }

    public static func settings(on date: Date, in rules: [PaySettings]) -> PaySettings? {
        rules.filter { $0.effectiveFrom <= date && (try? $0.validate()) != nil }.max {
            if $0.effectiveFrom != $1.effectiveFrom { return $0.effectiveFrom < $1.effectiveFrom }
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt < $1.modifiedAt }
            return canonicalData($0).lexicographicallyPrecedes(canonicalData($1))
        }
    }

    public static func attendanceStatus(on day: Date, asOf now: Date, entries: [WorkEntry]) -> AttendanceStatus {
        guard isReasonableDate(day), isReasonableDate(now) else { return .none }
        let records = mergedEntries(local: [], incoming: entries).filter {
            $0.deletedAt == nil && $0.kind == .regular && $0.start <= now &&
            MainlandWorkCalendar.calendar.isDate($0.start, inSameDayAs: day)
        }
        guard !records.isEmpty else { return .none }
        let conflicts = conflictingIDs(in: entries, asOf: now)
        if records.contains(where: { conflicts.contains($0.id) }) { return .conflict }
        return records.contains(where: { $0.isAttendance }) ? .recorded : .legacy
    }

    /// Date-only attendance uses China's civil date, independent of a picker's hidden time.
    public static func attendanceDate(_ date: Date, asOf now: Date) throws -> Date {
        guard isReasonableDate(date), isReasonableDate(now) else {
            throw PayValidationError.invalidRecord("出勤日期无效。")
        }
        let calendar = MainlandWorkCalendar.calendar
        let day = calendar.startOfDay(for: date)
        guard day <= calendar.startOfDay(for: now) else {
            throw PayValidationError.invalidRecord("不能记录未来出勤。")
        }
        return day
    }

    public static func attendanceDays(on date: Date, preserving previous: WorkEntry? = nil) throws -> Int {
        if let previous, let days = previous.attendanceWorkdays,
           MainlandWorkCalendar.calendar.isDate(date, equalTo: previous.start, toGranularity: .month) {
            return days
        }
        return try MainlandWorkCalendar.workdays(inMonthOf: date)
    }

    public static func attendance(on date: Date, settings: PaySettings, deviceID: String,
                                  among entries: [WorkEntry], replacing previous: WorkEntry? = nil) throws -> WorkEntry {
        let calendar = MainlandWorkCalendar.calendar
        let others = entries.filter { $0.id != previous?.id }
        guard !others.contains(where: {
            $0.deletedAt == nil && $0.kind == .regular && calendar.isDate($0.start, inSameDayAs: date)
        }) else { throw PayValidationError.invalidRecord("当天已有上班记录，请在工作记录中核对。") }
        let days = try attendanceDays(on: date, preserving: previous)
        var snapshot = previous?.settings ?? settings
        snapshot.paidDays = Decimal(days)
        let entry = WorkEntry(id: previous?.id ?? UUID(), start: date, end: date, kind: .regular, settings: snapshot,
                              deviceID: deviceID, attendanceWorkdays: days)
        try validate(entry, among: others, asOf: date)
        return entry
    }

    public static func summary(on day: Date, asOf now: Date, entries: [WorkEntry], calendar: Calendar) -> DaySummary {
        guard isReasonableDate(day), isReasonableDate(now), let dayRange = calendar.dateInterval(of: .day, for: day) else { return DaySummary() }
        let unique = mergedEntries(local: [], incoming: entries)
        let conflicts = conflictingIDs(in: unique, asOf: now)
        var regularSeconds: TimeInterval = 0
        var overtimeSeconds: TimeInterval = 0
        var regularAmount: Decimal = 0
        var overtimeAmount: Decimal = 0
        var paidAttendance = false
        for entry in unique where entry.deletedAt == nil && !conflicts.contains(entry.id) {
            if let days = entry.attendanceWorkdays {
                guard !paidAttendance, entry.kind == .regular, (1...31).contains(days),
                      entry.end == entry.start, entry.start <= now,
                      calendar.isDate(entry.start, inSameDayAs: day),
                      (try? entry.settings.validate()) != nil else { continue }
                regularAmount += entry.settings.monthlyBase / Decimal(days)
                paidAttendance = true
                continue
            }
            guard (try? entry.settings.validate()) != nil,
                  let interval = clipped(entry, to: dayRange, now: now) else { continue }
            let seconds = entry.kind == .regular ? normalSeconds(in: interval, entry: entry) : interval.duration
            let earnings = decimalSeconds(seconds) / 3600 * entry.settings.hourlyRate * entry.settings.multiplier(for: entry.kind)
            if entry.kind == .regular {
                regularSeconds += seconds; regularAmount += earnings
            } else {
                overtimeSeconds += seconds; overtimeAmount += earnings
            }
        }
        return DaySummary(regularSeconds: regularSeconds, overtimeSeconds: overtimeSeconds,
                          regularCents: cents(regularAmount), overtimeCents: cents(overtimeAmount))
    }

    public static func validate(_ entry: WorkEntry, among entries: [WorkEntry], asOf now: Date) throws {
        try entry.settings.validate()
        if let days = entry.attendanceWorkdays {
            guard entry.kind == .regular, entry.end == entry.start, (1...31).contains(days) else {
                throw PayValidationError.invalidRecord("按天出勤记录格式无效。")
            }
        }
        guard isReasonableDate(entry.start), isReasonableDate(entry.modifiedAt), isReasonableDate(now),
              entry.deletedAt.map(isReasonableDate) ?? true,
              entry.regularShiftAnchor.map(isReasonableDate) ?? true else {
            throw PayValidationError.invalidRecord("记录日期须在 1900 年至 2200 年之间。")
        }
        if let end = entry.end {
            guard isReasonableDate(end), end >= entry.start, end.timeIntervalSince(entry.start) <= 366 * 86400 else {
                throw PayValidationError.invalidRecord("结束时间不能早于开始时间，单条记录不能超过 366 天。")
            }
        }
        guard entry.start <= now.addingTimeInterval(1), (entry.end ?? now) <= now.addingTimeInterval(1) else {
            throw PayValidationError.invalidRecord("工作记录不能使用未来时间。")
        }
        guard !entry.deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PayValidationError.invalidRecord("记录缺少设备标识。")
        }
        if entry.deletedAt == nil {
            let others = mergedEntries(local: [], incoming: entries).filter { $0.id != entry.id }
            if entry.kind == .regular && others.contains(where: {
                $0.deletedAt == nil && $0.kind == .regular && (entry.isAttendance || $0.isAttendance) &&
                MainlandWorkCalendar.calendar.isDate($0.start, inSameDayAs: entry.start)
            }) { throw PayValidationError.invalidRecord("当天已有上班记录。") }
            if others.contains(where: { overlaps(entry, $0, now: now) }) { throw PayValidationError.overlap }
        }
    }

    public static func splitAtMidnight(_ entry: WorkEntry, calendar: Calendar) -> [WorkEntry] {
        guard let end = entry.end, isReasonableDate(entry.start), isReasonableDate(end),
              end > entry.start, end.timeIntervalSince(entry.start) <= 366 * 86400 else { return [entry] }
        var pieces: [WorkEntry] = []
        var cursor = entry.start
        while cursor < end {
            guard let day = calendar.dateInterval(of: .day, for: cursor), day.end > cursor else { return [entry] }
            let boundary = min(day.end, end)
            var piece = entry
            piece.start = cursor; piece.end = boundary
            if entry.kind == .regular { piece.regularShiftAnchor = regularShiftBounds(for: entry)?.start }
            if !pieces.isEmpty {
                piece.id = stableSplitID(original: entry.id, boundary: cursor)
                piece.needsTypeReview = entry.needsTypeReview || entry.kind != .regular
            }
            pieces.append(piece)
            cursor = boundary
        }
        return pieces
    }

    /// Last writer wins per ID, with deterministic payload ties and deletion precedence.
    public static func mergedEntries(local: [WorkEntry], incoming: [WorkEntry]) -> [WorkEntry] {
        var byID: [UUID: WorkEntry] = [:]
        for candidate in local + incoming {
            if let current = byID[candidate.id] {
                if wins(candidate, over: current) { byID[candidate.id] = candidate }
            } else { byID[candidate.id] = candidate }
        }
        return byID.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public static func conflictingIDs(in entries: [WorkEntry], asOf now: Date) -> Set<UUID> {
        let unique = mergedEntries(local: [], incoming: entries).filter { $0.deletedAt == nil }.sorted { $0.start < $1.start }
        var result: Set<UUID> = []
        // An old-device hourly record and a new attendance record for the same day
        // need review even when their timestamps do not overlap.
        for attendance in unique where attendance.isAttendance {
            for legacy in unique where legacy.kind == .regular && !legacy.isAttendance {
                if MainlandWorkCalendar.calendar.isDate(attendance.start, inSameDayAs: legacy.start) {
                    result.insert(attendance.id); result.insert(legacy.id)
                }
            }
        }
        for i in unique.indices {
            let end = unique[i].end ?? now.addingTimeInterval(0.001)
            for j in unique.index(after: i)..<unique.endIndex {
                if unique[j].start >= end { break }
                if overlaps(unique[i], unique[j], now: now) {
                    result.insert(unique[i].id); result.insert(unique[j].id)
                }
            }
        }
        return result
    }

    /// Full monthly base plus accrued overtime. Midmonth changes use the latest effective
    /// base; proration, absence and taxes remain explicit ledger adjustments.
    public static func monthlyEstimate(on date: Date, settings rules: [PaySettings], entries: [WorkEntry], asOf now: Date, calendar: Calendar) -> Int64 {
        guard isReasonableDate(date), isReasonableDate(now), let month = calendar.dateInterval(of: .month, for: date) else { return 0 }
        let ruleDate = max(month.start, min(now, month.end.addingTimeInterval(-0.001)))
        var total = settings(on: ruleDate, in: rules)?.monthlyBase ?? 0
        let unique = mergedEntries(local: [], incoming: entries)
        let conflicts = conflictingIDs(in: unique, asOf: now)
        for entry in unique where entry.deletedAt == nil && entry.kind != .regular && !conflicts.contains(entry.id) {
            guard (try? entry.settings.validate()) != nil, let interval = clipped(entry, to: month, now: now) else { continue }
            total += decimalSeconds(interval.duration) / 3600 * entry.settings.hourlyRate * entry.settings.multiplier(for: entry.kind)
        }
        return cents(total)
    }

    static func isReasonableDate(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && seconds >= -2_208_988_800 && seconds < 7_258_118_400
    }

    static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? (rhs >= 0 ? .max : .min) : result.partialValue
    }

    private static func clipped(_ entry: WorkEntry, to interval: DateInterval, now: Date) -> DateInterval? {
        guard isReasonableDate(entry.start), entry.end.map(isReasonableDate) ?? true else { return nil }
        let start = max(entry.start, interval.start)
        let end = min(entry.end ?? now, now, interval.end)
        return end > start ? DateInterval(start: start, end: end) : nil
    }

    private static func overlaps(_ lhs: WorkEntry, _ rhs: WorkEntry, now: Date) -> Bool {
        guard !lhs.isAttendance, !rhs.isAttendance, lhs.id != rhs.id, lhs.deletedAt == nil, rhs.deletedAt == nil,
              isReasonableDate(lhs.start), isReasonableDate(rhs.start) else { return false }
        let leftEnd = lhs.end ?? now.addingTimeInterval(0.001)
        let rightEnd = rhs.end ?? now.addingTimeInterval(0.001)
        guard isReasonableDate(leftEnd), isReasonableDate(rightEnd), leftEnd > lhs.start, rightEnd > rhs.start else { return false }
        return max(lhs.start, rhs.start) < min(leftEnd, rightEnd)
    }

    private static func regularShiftBounds(for entry: WorkEntry) -> DateInterval? {
        let rule = entry.settings
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: rule.timeZoneID) ?? TimeZone(secondsFromGMT: 0)!
        let overnight = rule.endMinute <= rule.startMinute
        let origin = entry.regularShiftAnchor ?? entry.start
        guard isReasonableDate(origin) else { return nil }
        var day = calendar.startOfDay(for: origin)
        if entry.regularShiftAnchor == nil, overnight,
           let morningEnd = wallTime(rule.endMinute, on: day, calendar: calendar), entry.start < morningEnd {
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { return nil }
            day = previous
        }
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day),
              let start = wallTime(rule.startMinute, on: day, calendar: calendar),
              let end = wallTime(rule.endMinute, on: overnight ? nextDay : day, calendar: calendar), end > start else { return nil }
        return DateInterval(start: start, end: end)
    }

    private static func normalSeconds(in interval: DateInterval, entry: WorkEntry) -> TimeInterval {
        guard let shift = regularShiftBounds(for: entry) else { return 0 }
        let start = max(interval.start, shift.start)
        let end = min(interval.end, shift.end)
        guard end > start else { return 0 }
        let rule = entry.settings
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: rule.timeZoneID) ?? TimeZone(secondsFromGMT: 0)!
        var seconds = end.timeIntervalSince(start)
        if rule.breakStartMinute != rule.breakEndMinute {
            // Only the original shift can earn regular pay, even if its timer remains
            // open for days. Civil break intervals may still straddle its midnight.
            guard var breakDay = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: start)) else { return 0 }
            while breakDay < end {
                guard let following = calendar.date(byAdding: .day, value: 1, to: breakDay),
                      let breakStart = wallTime(rule.breakStartMinute, on: breakDay, calendar: calendar),
                      let breakEnd = wallTime(rule.breakEndMinute, on: rule.breakEndMinute <= rule.breakStartMinute ? following : breakDay, calendar: calendar) else { break }
                seconds -= max(0, min(end, breakEnd).timeIntervalSince(max(start, breakStart)))
                breakDay = following
            }
        }
        return max(0, seconds)
    }

    private static func wallTime(_ minute: Int, on day: Date, calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day,
                      matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    }

    private static func decimalSeconds(_ seconds: TimeInterval) -> Decimal {
        Decimal(string: String(seconds), locale: Locale(identifier: "en_US_POSIX")) ?? 0
    }

    private static func wins(_ candidate: WorkEntry, over current: WorkEntry) -> Bool {
        if candidate.modifiedAt != current.modifiedAt { return candidate.modifiedAt > current.modifiedAt }
        if (candidate.deletedAt != nil) != (current.deletedAt != nil) { return candidate.deletedAt != nil }
        return canonicalData(current).lexicographicallyPrecedes(canonicalData(candidate))
    }

    private static func canonicalData<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data()
    }

    private static func stableSplitID(original: UUID, boundary: Date) -> UUID {
        let key = original.uuidString + ":" + String(boundary.timeIntervalSince1970.bitPattern)
        func hash(seed: UInt64) -> UInt64 {
            key.utf8.reduce(seed) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        }
        let first = hash(seed: 14_695_981_039_346_656_037)
        let second = hash(seed: 7_809_847_782_465_536_322)
        var bytes = (0..<8).map { UInt8(truncatingIfNeeded: first >> (8 * (7 - $0))) }
        bytes += (0..<8).map { UInt8(truncatingIfNeeded: second >> (8 * (7 - $0))) }
        bytes[6] = (bytes[6] & 0x0f) | 0x80; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
