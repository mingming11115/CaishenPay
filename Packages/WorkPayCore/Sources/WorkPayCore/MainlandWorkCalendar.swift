import Foundation

/// Mainland China national holiday schedule, including substitute working weekends.
/// Source: State Council General Office, 国办发明电〔2025〕7号.
/// https://www.beijing.gov.cn/fuwu/bmfw/sy/jrts/202511/t20251104_4258838.html
/// Missing years must not silently fall back to a Monday–Friday estimate.
public enum MainlandWorkCalendar {
    public static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    private static let holidays2026: Set<Int> = Set(
        [101, 102, 103] + Array(215...223) + Array(404...406) + Array(501...505)
        + Array(619...621) + Array(925...927) + Array(1001...1007)
    )
    private static let makeup2026: Set<Int> = [104, 214, 228, 509, 920, 1010]

    public static func isWorkday(_ date: Date) throws -> Bool {
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        guard parts.year == 2026 else {
            throw PayValidationError.invalidSettings("尚未收录\(parts.year ?? 0)年中国大陆节假日及调休安排，请更新日历数据后记薪。")
        }
        let key = parts.month! * 100 + parts.day!
        if makeup2026.contains(key) { return true }
        if holidays2026.contains(key) { return false }
        return parts.weekday != 1 && parts.weekday != 7
    }

    public static func workdays(inMonthOf date: Date) throws -> Int {
        guard PayEngine.isReasonableDate(date), let month = calendar.dateInterval(of: .month, for: date) else {
            throw PayValidationError.invalidSettings("月份无效。")
        }
        var cursor = month.start
        var count = 0
        while cursor < month.end {
            if try isWorkday(cursor) { count += 1 }
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        return count
    }
}
