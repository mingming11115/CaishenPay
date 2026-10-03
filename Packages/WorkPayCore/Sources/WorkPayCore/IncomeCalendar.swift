import Foundation

public struct DailyIncome: Identifiable, Equatable, Sendable {
    public let date: Date
    public let summary: DaySummary
    public let hasRecords: Bool
    public let hasConflict: Bool
    public let isFuture: Bool
    public var id: Date { date }
}

extension PayEngine {
    /// Actual recorded earnings, never the full-base monthly payroll estimate.
    public static func incomeCalendar(inMonthOf date: Date, asOf now: Date,
                                      entries: [WorkEntry], calendar: Calendar) -> [DailyIncome] {
        guard isReasonableDate(date), isReasonableDate(now),
              let month = calendar.dateInterval(of: .month, for: date) else { return [] }
        let unique = mergedEntries(local: [], incoming: entries).filter { $0.deletedAt == nil }
        let conflicts = conflictingIDs(in: unique, asOf: now)
        let today = calendar.startOfDay(for: now)
        var cursor = month.start
        var days: [DailyIncome] = []
        while cursor < month.end {
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            let records = unique.filter { entry in
                guard entry.start <= now else { return false }
                if entry.isAttendance { return calendar.isDate(entry.start, inSameDayAs: cursor) }
                return entry.start < next && (entry.end ?? now) > cursor
            }
            days.append(DailyIncome(date: cursor,
                summary: summary(on: cursor, asOf: now, entries: unique, calendar: calendar),
                hasRecords: !records.isEmpty,
                hasConflict: records.contains { conflicts.contains($0.id) }, isFuture: cursor > today))
            cursor = next
        }
        return days
    }
}
