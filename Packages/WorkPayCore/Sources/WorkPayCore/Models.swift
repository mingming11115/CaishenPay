import Foundation

public enum AttendanceStatus: Equatable, Sendable {
    case none, recorded, legacy, conflict
}

public enum WorkKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case regular, weekday, weekend, holiday
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .regular: return "正常上班"
        case .weekday: return "工作日加班"
        case .weekend: return "休息日加班"
        case .holiday: return "节假日加班"
        }
    }
}

public struct PaySettings: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var effectiveFrom: Date
    public var monthlyBase: Decimal
    public var paidDays: Decimal
    public var dailyHours: Decimal
    public var weekdayMultiplier: Decimal
    public var weekendMultiplier: Decimal
    public var holidayMultiplier: Decimal
    public var startMinute: Int
    public var endMinute: Int
    public var breakStartMinute: Int
    public var breakEndMinute: Int
    public var timeZoneID: String
    public var modifiedAt: Date

    public init(id: UUID = UUID(), effectiveFrom: Date, monthlyBase: Decimal,
                paidDays: Decimal = Decimal(string: "21.75")!, dailyHours: Decimal = 8,
                weekdayMultiplier: Decimal = Decimal(string: "1.5")!, weekendMultiplier: Decimal = 2,
                holidayMultiplier: Decimal = 3, startMinute: Int = 540, endMinute: Int = 1080,
                breakStartMinute: Int = 720, breakEndMinute: Int = 780,
                timeZoneID: String = "Asia/Shanghai", modifiedAt: Date = Date()) {
        self.id = id; self.effectiveFrom = effectiveFrom; self.monthlyBase = monthlyBase
        self.paidDays = paidDays; self.dailyHours = dailyHours
        self.weekdayMultiplier = weekdayMultiplier; self.weekendMultiplier = weekendMultiplier
        self.holidayMultiplier = holidayMultiplier; self.startMinute = startMinute
        self.endMinute = endMinute; self.breakStartMinute = breakStartMinute
        self.breakEndMinute = breakEndMinute; self.timeZoneID = timeZoneID; self.modifiedAt = modifiedAt
    }

    public var hourlyRate: Decimal {
        guard !monthlyBase.isNaN, !paidDays.isNaN, !dailyHours.isNaN,
              monthlyBase >= 0, paidDays > 0, dailyHours > 0 else { return 0 }
        let rate = monthlyBase / paidDays / dailyHours
        return rate.isNaN ? 0 : rate
    }
    public func multiplier(for kind: WorkKind) -> Decimal {
        switch kind {
        case .regular: return 1
        case .weekday: return weekdayMultiplier
        case .weekend: return weekendMultiplier
        case .holiday: return holidayMultiplier
        }
    }
    public func validate() throws {
        let upper = Decimal(PayEngine.maximumAmountCents) / 100
        guard !monthlyBase.isNaN, monthlyBase >= 0, monthlyBase <= upper else {
            throw PayValidationError.invalidSettings("月薪必须为不小于零且不超过一万亿元的金额。")
        }
        guard !paidDays.isNaN, paidDays > 0, paidDays <= 366,
              !dailyHours.isNaN, dailyHours > 0, dailyHours <= 24 else {
            throw PayValidationError.invalidSettings("计薪天数须大于 0 且不超过 366；每日计薪小时须大于 0 且不超过 24。")
        }
        let rawRate = monthlyBase / paidDays / dailyHours
        guard !rawRate.isNaN, rawRate <= upper else {
            throw PayValidationError.invalidSettings("折算时薪过大，请检查月薪、计薪天数和每日小时。")
        }
        for multiplier in [weekdayMultiplier, weekendMultiplier, holidayMultiplier] {
            guard !multiplier.isNaN, multiplier > 0, multiplier <= 100 else {
                throw PayValidationError.invalidSettings("加班倍率须大于 0 且不超过 100。")
            }
        }
        guard [startMinute, endMinute, breakStartMinute, breakEndMinute].allSatisfy({ (0..<1440).contains($0) }),
              TimeZone(identifier: timeZoneID) != nil else {
            throw PayValidationError.invalidSettings("班段时间或时区无效。")
        }
        guard PayEngine.isReasonableDate(effectiveFrom), PayEngine.isReasonableDate(modifiedAt) else {
            throw PayValidationError.invalidSettings("规则日期须在 1900 年至 2200 年之间。")
        }
    }
}

public struct WorkEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var start: Date
    public var end: Date?
    public var kind: WorkKind
    public var settings: PaySettings
    public var deviceID: String
    public var modifiedAt: Date
    public var deletedAt: Date?
    public var needsTypeReview: Bool
    /// Scheduled start of the original regular shift. Split pieces retain this anchor;
    /// nil records infer it from their original start for backward-compatible decoding.
    public var regularShiftAnchor: Date?
    /// Non-nil marks a full attendance day; snapshot survives calendar updates.
    public var attendanceWorkdays: Int?
    public var isAttendance: Bool { attendanceWorkdays != nil }

    public init(id: UUID = UUID(), start: Date, end: Date? = nil, kind: WorkKind,
                settings: PaySettings, deviceID: String, modifiedAt: Date = Date(),
                deletedAt: Date? = nil, needsTypeReview: Bool = false, regularShiftAnchor: Date? = nil, attendanceWorkdays: Int? = nil) {
        self.id = id; self.start = start; self.end = end; self.kind = kind
        self.settings = settings; self.deviceID = deviceID; self.modifiedAt = modifiedAt
        self.deletedAt = deletedAt; self.needsTypeReview = needsTypeReview
        self.regularShiftAnchor = regularShiftAnchor
        self.attendanceWorkdays = attendanceWorkdays
    }
}

public struct SalaryPayment: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var amountCents: Int64
    public var paidAt: Date
    public var note: String
    public init(id: UUID = UUID(), amountCents: Int64, paidAt: Date, note: String = "") {
        self.id = id; self.amountCents = amountCents; self.paidAt = paidAt; self.note = note
    }
}

public struct SalaryMonth: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var expectedCents: Int64
    public var payments: [SalaryPayment]
    public var note: String
    public var modifiedAt: Date
    public init(id: String, expectedCents: Int64, payments: [SalaryPayment] = [],
                note: String = "", modifiedAt: Date = Date()) {
        self.id = id; self.expectedCents = expectedCents; self.payments = payments
        self.note = note; self.modifiedAt = modifiedAt
    }
    public var receivedCents: Int64 {
        payments.reduce(Int64(0)) { PayEngine.saturatingAdd($0, max(0, $1.amountCents)) }
    }
    public var outstandingCents: Int64 { max(0, max(0, expectedCents) - receivedCents) }
    public var overpaidCents: Int64 { max(0, receivedCents - max(0, expectedCents)) }
}

public struct PayData: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var settings: [PaySettings]
    public var entries: [WorkEntry]
    public var salaryMonths: [SalaryMonth]
    public var hasCompletedSetup: Bool
    public init() {
        schemaVersion = 1; settings = []; entries = []; salaryMonths = []; hasCompletedSetup = false
    }
}

public struct DaySummary: Equatable, Sendable {
    public var regularSeconds: TimeInterval
    public var overtimeSeconds: TimeInterval
    public var regularCents: Int64
    public var overtimeCents: Int64
    public init(regularSeconds: TimeInterval = 0, overtimeSeconds: TimeInterval = 0,
                regularCents: Int64 = 0, overtimeCents: Int64 = 0) {
        self.regularSeconds = regularSeconds; self.overtimeSeconds = overtimeSeconds
        self.regularCents = regularCents; self.overtimeCents = overtimeCents
    }
    public var totalSeconds: TimeInterval { regularSeconds + overtimeSeconds }
    public var totalCents: Int64 { PayEngine.saturatingAdd(regularCents, overtimeCents) }
}

public enum PayValidationError: Error, LocalizedError, Equatable, Sendable {
    case invalidSettings(String)
    case invalidRecord(String)
    case overlap
    case invalidLedger(String)
    case unsupportedSchema(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidSettings(let message), .invalidRecord(let message), .invalidLedger(let message): return message
        case .overlap: return "该时段与已有记录重叠，请先修正冲突记录。"
        case .unsupportedSchema(let version): return "数据版本 \(version) 暂不受支持，请保留原文件并更新应用。"
        }
    }
}
