import Foundation

extension SalaryPayment {
    public func validate() throws {
        guard amountCents > 0, amountCents <= PayEngine.maximumAmountCents else {
            throw PayValidationError.invalidLedger("到账金额须大于零且不超过一万亿元。")
        }
        guard PayEngine.isReasonableDate(paidAt) else {
            throw PayValidationError.invalidLedger("到账日期须在 1900 年至 2200 年之间。")
        }
        guard note.count <= 10_000 else { throw PayValidationError.invalidLedger("到账备注过长。") }
    }
}

extension SalaryMonth {
    public func validate() throws {
        let components = id.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == 2, components[0].count == 4, components[1].count == 2,
              let year = Int(components[0]), let month = Int(components[1]),
              (1900..<2200).contains(year), (1...12).contains(month),
              id == String(format: "%04d-%02d", year, month) else {
            throw PayValidationError.invalidLedger("工资所属月份无效，请使用 年-月 格式。")
        }
        guard expectedCents >= 0, expectedCents <= PayEngine.maximumAmountCents else {
            throw PayValidationError.invalidLedger("应收金额须不小于零且不超过一万亿元。")
        }
        guard PayEngine.isReasonableDate(modifiedAt), note.count <= 10_000 else {
            throw PayValidationError.invalidLedger("工资账本日期或备注无效。")
        }
        guard Set(payments.map(\.id)).count == payments.count else {
            throw PayValidationError.invalidLedger("同一笔到账不能重复保存。")
        }
        for payment in payments { try payment.validate() }
        guard receivedCents <= PayEngine.maximumAmountCents else {
            throw PayValidationError.invalidLedger("累计到账金额过大。")
        }
    }
}

public enum PayDataCodec {
    public static func encode(_ data: PayData) throws -> Data {
        try validate(data)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(data)
    }

    public static func decode(_ bytes: Data) throws -> PayData {
        let data = try JSONDecoder().decode(PayData.self, from: bytes)
        try validate(data)
        return data
    }

    public static func read(from url: URL) throws -> PayData {
        try decode(Data(contentsOf: url))
    }

    /// Validation and encoding finish before the atomic replacement. Failure leaves
    /// the previous file intact and is propagated to the caller for a visible error.
    public static func write(_ data: PayData, to url: URL) throws {
        let bytes = try encode(data)
        try bytes.write(to: url, options: .atomic)
    }

    private static func validate(_ data: PayData) throws {
        guard data.schemaVersion == 1 else { throw PayValidationError.unsupportedSchema(data.schemaVersion) }
        guard Set(data.settings.map(\.id)).count == data.settings.count,
              Set(data.entries.map(\.id)).count == data.entries.count,
              Set(data.salaryMonths.map(\.id)).count == data.salaryMonths.count else {
            throw PayValidationError.invalidRecord("数据包含重复标识，请保留原文件并修复。")
        }
        for setting in data.settings { try setting.validate() }
        let now = Date()
        // Preserve legitimate offline conflicts for review; do not silently discard either record.
        for entry in data.entries { try PayEngine.validate(entry, among: [], asOf: now) }
        for month in data.salaryMonths { try month.validate() }
        let paymentIDs = data.salaryMonths.flatMap { $0.payments.map(\.id) }
        guard Set(paymentIDs).count == paymentIDs.count else {
            throw PayValidationError.invalidLedger("一笔到账不能归入多个工资月份。")
        }
    }
}
