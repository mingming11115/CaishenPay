import Foundation
import Combine
import WorkPayCore

private struct PayDiskState: Codable {
    var version = 1
    var deviceID: String
    var data: PayData
    var pendingEntries: [WorkEntry] = []
    var receivedWatchEntries: [WorkEntry] = []
    var phoneRevision: Int64 = 0
    var phoneDeviceID: String?
    var phoneData: PayData?
    var lastSync: Date?
}

@MainActor
final class PayStore: ObservableObject {
    @Published private(set) var data: PayData
    @Published var errorMessage: String?
    @Published private(set) var syncStatus = "尚未同步"
    @Published private(set) var lastSync: Date?
    @Published private(set) var pendingCount = 0

    private var state: PayDiskState
    private let storageURL: URL
    private let demo: Bool
    private var persistenceBlocked = false
    private var connectivity: ConnectivityService?

    var deviceID: String { state.deviceID }
    var currentSettings: PaySettings? { PayEngine.settings(on: Date(), in: data.settings) }
    var activeEntry: WorkEntry? {
        let active = data.entries.filter { $0.deletedAt == nil && $0.end == nil }
        return active.first(where: { $0.deviceID == deviceID }) ?? active.sorted { $0.start < $1.start }.first
    }
    var conflictIDs: Set<UUID> { PayEngine.conflictingIDs(in: data.entries, asOf: Date()) }

    init(demo: Bool = false) {
        self.demo = demo
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CaishenPay", isDirectory: true)
        storageURL = directory.appendingPathComponent("pay-state-v1.json")
        let initial = PayDiskState(deviceID: UUID().uuidString, data: PayData())
        state = initial
        data = initial.data
        if demo {
            state.data = Self.demoData(deviceID: state.deviceID)
            data = state.data
            syncStatus = "演示模式 · 不保存、不连接设备"
            return
        }
        do {
            if FileManager.default.fileExists(atPath: storageURL.path) {
                let saved = try JSONDecoder().decode(PayDiskState.self, from: Data(contentsOf: storageURL))
                guard saved.version == 1, saved.data.schemaVersion == 1 else { throw StoreError.unsupportedVersion }
                guard !saved.deviceID.isEmpty, saved.phoneRevision >= 0,
                      Set(saved.pendingEntries.map(\.id)).count == saved.pendingEntries.count,
                      Set(saved.receivedWatchEntries.map(\.id)).count == saved.receivedWatchEntries.count else {
                    throw StoreError.message("同步记录格式异常，已停止覆盖")
                }
                try Self.validateStructure(saved.data)
                if let phoneData = saved.phoneData { try Self.validateStructure(phoneData) }
                for entry in saved.pendingEntries + saved.receivedWatchEntries { try Self.validateRecord(entry) }
                state = saved
                data = saved.data
                lastSync = saved.lastSync
                pendingCount = saved.pendingEntries.count
            } else {
                try Self.write(initial, to: storageURL)
            }
        } catch {
            persistenceBlocked = true
            errorMessage = "本地数据无法读取或保存，原文件已保留。请勿卸载应用；请检查设备存储空间。\n\(error.localizedDescription)"
            syncStatus = "本地存储需要检查"
        }
        guard !persistenceBlocked else { return }
        let service = ConnectivityService()
        service.onReceive = { [weak self] packet in self?.receive(packet) }
        service.onStatus = { [weak self] status in self?.syncStatus = status }
        service.onReady = { [weak self] in self?.refreshSync() }
        connectivity = service
        service.activate()
    }

    func summary(on date: Date, now: Date = Date()) -> DaySummary {
        PayEngine.summary(on: date, asOf: now, entries: data.entries, calendar: calendar(on: date))
    }

    var attendanceStatusToday: AttendanceStatus {
        PayEngine.attendanceStatus(on: Date(), asOf: Date(), entries: data.entries)
    }

    var attendanceStatusText: String {
        switch attendanceStatusToday {
        case .none: return "今日尚未记录上班"
        case .recorded: return "今日已记上班 · 1天"
        case .legacy: return "今日有旧版计时记录 · 按原规则计薪"
        case .conflict: return "今日上班记录有冲突 · 请核对"
        }
    }

    func markToday(at date: Date = Date()) {
        saveAttendance(on: date)
    }

    func saveAttendance(on date: Date, replacing previous: WorkEntry? = nil) {
        perform {
            #if os(watchOS)
            throw StoreError.message("请在 iPhone 记录正常出勤")
            #else
            let day = try PayEngine.attendanceDate(date, asOf: Date())
            guard data.hasCompletedSetup,
                  let settings = previous?.settings ?? PayEngine.settings(on: day, in: data.settings) else {
                throw StoreError.message("该日期没有生效的工资规则，请先设置工资")
            }
            var entry = try PayEngine.attendance(on: day, settings: settings, deviceID: deviceID,
                                                 among: data.entries, replacing: previous)
            if let previous { entry.modifiedAt = nextRevision(after: previous.modifiedAt) }
            try Self.validateRecord(entry)
            var next = state
            upsert([entry], in: &next)
            try commit(next)
            #endif
        }
    }

    func begin(_ kind: WorkKind, at date: Date = Date()) {
        perform {
            guard kind != .regular else { throw StoreError.message("正常上班请使用今日上班，按天记录") }
            guard data.hasCompletedSetup, var settings = PayEngine.settings(on: date, in: data.settings) else {
                throw StoreError.message("请先在 iPhone 设置工资与班次")
            }
            guard activeEntry == nil else { throw StoreError.message("请先结束当前计时") }
            settings.paidDays = Decimal(try MainlandWorkCalendar.workdays(inMonthOf: date))
            let entry = WorkEntry(start: date, kind: kind, settings: settings, deviceID: deviceID)
            try Self.validateRecord(entry)
            try PayEngine.validate(entry, among: data.entries, asOf: Date())
            var next = state
            upsert([entry], in: &next)
            try commit(next)
        }
    }

    func stop(at date: Date = Date()) {
        perform {
            guard var entry = activeEntry else { throw StoreError.message("当前没有正在计时的记录") }
            #if os(watchOS)
            guard entry.kind != .regular else { throw StoreError.message("正常上班计时请在手机结束") }
            #endif
            entry.end = date
            entry.modifiedAt = nextRevision(after: entry.modifiedAt)
            try Self.validateRecord(entry)
            // Ending an overlapping timer is allowed; conflicts still require correction on iPhone.
            try PayEngine.validate(entry, among: [], asOf: Date())
            let parts = PayEngine.splitAtMidnight(entry, calendar: calendar(for: entry.settings))
            var next = state
            upsert(parts, in: &next)
            try commit(next)
        }
    }

    func saveSettings(_ settings: PaySettings) {
        perform {
            #if os(watchOS)
            throw StoreError.message("请在 iPhone 修改工资设置")
            #else
            try settings.validate()
            try Self.validateDate(settings.effectiveFrom, allowFuture: true)
            var rule = settings
            rule.modifiedAt = Date()
            if data.settings.contains(where: { $0.id == rule.id }) { rule.id = UUID() }
            var next = state
            if rule.effectiveFrom <= Date(), var active = activeEntry {
                active.end = Date()
                active.modifiedAt = nextRevision(after: active.modifiedAt)
                try Self.validateRecord(active)
                upsert(PayEngine.splitAtMidnight(active, calendar: calendar(for: active.settings)), in: &next)
            }
            next.data.settings.append(rule)
            next.data.hasCompletedSetup = true
            try commit(next)
            #endif
        }
    }

    func saveEntry(_ entry: WorkEntry) {
        perform {
            #if os(watchOS)
            throw StoreError.message("请在 iPhone 修正工作记录")
            #else
            var updated = entry
            let previous = data.entries.first { $0.id == entry.id }
            updated.modifiedAt = nextRevision(after: previous?.modifiedAt ?? entry.modifiedAt)
            try Self.validateRecord(updated)
            if updated.end == nil && data.entries.contains(where: { $0.id != updated.id && $0.deletedAt == nil && $0.end == nil }) {
                throw StoreError.message("已有正在计时的记录，请先结束")
            }
            try PayEngine.validate(updated, among: data.entries, asOf: Date())
            let parts = updated.end == nil ? [updated] : PayEngine.splitAtMidnight(updated, calendar: calendar(for: updated.settings))
            var next = state
            upsert(parts, in: &next)
            try commit(next)
            #endif
        }
    }

    func deleteEntry(_ id: UUID) {
        perform {
            #if os(watchOS)
            throw StoreError.message("请在 iPhone 删除工作记录")
            #else
            guard var entry = data.entries.first(where: { $0.id == id }) else { return }
            entry.deletedAt = Date()
            entry.modifiedAt = nextRevision(after: entry.modifiedAt)
            var next = state
            upsert([entry], in: &next)
            try commit(next)
            #endif
        }
    }

    func saveMonth(_ month: SalaryMonth) {
        perform {
            #if os(watchOS)
            throw StoreError.message("请在 iPhone 修改工资账本")
            #else
            try month.validate()
            var updated = month
            updated.modifiedAt = nextRevision(after: data.salaryMonths.first(where: { $0.id == month.id })?.modifiedAt ?? month.modifiedAt)
            var next = state
            next.data.salaryMonths.removeAll { $0.id == month.id }
            next.data.salaryMonths.append(updated)
            try commit(next)
            #endif
        }
    }

    func month(_ id: String) -> SalaryMonth? { data.salaryMonths.first { $0.id == id } }

    func estimatedMonth(_ date: Date) -> Int64 {
        PayEngine.monthlyEstimate(on: date, settings: data.settings, entries: data.entries, asOf: Date(), calendar: calendar(on: date))
    }

    func refreshSync() {
        guard !demo, !persistenceBlocked else { return }
        #if os(watchOS)
        let packet = PaySyncPacket(source: .watch, deviceID: deviceID, revision: state.phoneRevision,
                                   data: nil, entries: state.pendingEntries, acknowledged: [])
        #else
        let packet = PaySyncPacket(source: .phone, deviceID: deviceID, revision: state.phoneRevision,
                                   data: data, entries: [], acknowledged: state.receivedWatchEntries)
        #endif
        connectivity?.send(packet)
    }

    private func receive(_ packet: PaySyncPacket) {
        guard !demo, !persistenceBlocked, packet.deviceID != deviceID else { return }
        do {
            var next = state
            #if os(watchOS)
            guard packet.source == .phone, let incoming = packet.data else { return }
            try Self.validateStructure(incoming)
            for entry in packet.acknowledged { try Self.validateRecord(entry) }
            // Removing a pending edit requires acknowledgement of its entire exact revision.
            next.pendingEntries = PayEngine.pendingEntries(afterAcknowledging: next.pendingEntries, acknowledged: packet.acknowledged)
            if next.phoneDeviceID != packet.deviceID || packet.revision >= next.phoneRevision {
                next.phoneData = incoming
                next.phoneDeviceID = packet.deviceID
                next.phoneRevision = packet.revision
            }
            next.data = next.phoneData ?? next.data
            // Unsent edits win or remain visible as conflicts even while a snapshot is arriving.
            next.data.entries = PayEngine.mergedEntries(local: next.data.entries, incoming: next.pendingEntries)
            #else
            guard packet.source == .watch else { return }
            for entry in packet.entries { try Self.validateRecord(entry) }
            next.data.entries = PayEngine.mergedEntries(local: next.data.entries, incoming: packet.entries)
            next.receivedWatchEntries = PayEngine.mergedEntries(local: next.receivedWatchEntries, incoming: packet.entries)
            #endif
            next.lastSync = Date()
            try commit(next, synchronize: false)
            syncStatus = pendingCount == 0 ? "已同步" : "部分记录等待同步"
            #if os(watchOS)
            if pendingCount > 0 { refreshSync() }
            #else
            refreshSync()
            #endif
        } catch {
            errorMessage = "同步未保存，本机数据已保留。\(error.localizedDescription)"
            syncStatus = "同步需要重试"
        }
    }

    private func upsert(_ entries: [WorkEntry], in next: inout PayDiskState) {
        next.data.entries = PayEngine.mergedEntries(local: next.data.entries, incoming: entries)
        #if os(watchOS)
        next.pendingEntries = PayEngine.mergedEntries(local: next.pendingEntries, incoming: entries)
        #endif
    }

    private func commit(_ candidate: PayDiskState, synchronize: Bool = true) throws {
        guard !persistenceBlocked else { throw StoreError.message("本地数据文件已保留，请先处理存储错误") }
        var next = candidate
        try Self.validateStructure(next.data)
        #if os(iOS)
        if next.data != state.data || next.receivedWatchEntries != state.receivedWatchEntries {
            next.phoneRevision = state.phoneRevision + 1
        }
        #endif
        if !demo { try Self.write(next, to: storageURL) }
        state = next
        data = next.data
        lastSync = next.lastSync
        pendingCount = next.pendingEntries.count
        if synchronize { refreshSync() }
    }

    private func perform(_ action: () throws -> Void) {
        errorMessage = nil
        do {
            guard !persistenceBlocked else { throw StoreError.message("本地数据文件已保留，请先处理存储错误") }
            try action()
        } catch { errorMessage = error.localizedDescription }
    }

    private func calendar(on date: Date) -> Calendar {
        calendar(for: PayEngine.settings(on: date, in: data.settings) ?? currentSettings)
    }

    private func calendar(for settings: PaySettings?) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: settings?.timeZoneID ?? "Asia/Shanghai") ?? .current
        return calendar
    }

    private func nextRevision(after previous: Date) -> Date {
        max(Date(), previous.addingTimeInterval(0.001))
    }

    private static func write(_ state: PayDiskState, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(state)
        // Atomic replacement leaves the previous complete document intact if writing fails.
        try bytes.write(to: url, options: .atomic)
    }

    private static func validateStructure(_ data: PayData) throws {
        guard data.schemaVersion == 1 else { throw StoreError.unsupportedVersion }
        guard Set(data.entries.map(\.id)).count == data.entries.count,
              Set(data.settings.map(\.id)).count == data.settings.count,
              Set(data.salaryMonths.map(\.id)).count == data.salaryMonths.count else {
            throw StoreError.message("数据中存在重复标识，已停止覆盖")
        }
        for rule in data.settings { try rule.validate(); try validateDate(rule.effectiveFrom, allowFuture: true) }
        for entry in data.entries { try validateRecord(entry) }
        for month in data.salaryMonths { try month.validate() }
        let paymentIDs = data.salaryMonths.flatMap { $0.payments.map(\.id) }
        guard Set(paymentIDs).count == paymentIDs.count else {
            throw StoreError.message("同一笔到账不能重复归入多个工资月份")
        }
        if data.hasCompletedSetup && data.settings.isEmpty { throw StoreError.message("工资设置缺失") }
    }

    private static func validateRecord(_ entry: WorkEntry) throws {
        try entry.settings.validate()
        if let days = entry.attendanceWorkdays {
            guard entry.kind == .regular, entry.end == entry.start, (1...31).contains(days) else {
                throw StoreError.message("按天出勤记录格式无效")
            }
        }
        try validateDate(entry.start)
        try validateDate(entry.modifiedAt, allowFuture: true)
        if let end = entry.end {
            try validateDate(end)
            guard end > entry.start || (entry.isAttendance && end == entry.start) else { throw StoreError.message("结束时间必须晚于开始时间") }
            guard end.timeIntervalSince(entry.start) <= 366 * 86_400 else {
                throw StoreError.message("单条工作记录不能超过 366 天")
            }
        }
        if let deleted = entry.deletedAt { try validateDate(deleted, allowFuture: true) }
        guard !entry.deviceID.isEmpty else { throw StoreError.message("工作记录缺少设备标识") }
    }

    private static func validateDate(_ date: Date, allowFuture: Bool = false) throws {
        let value = date.timeIntervalSince1970
        let upper = allowFuture ? Date().addingTimeInterval(366 * 86_400 * 10) : Date().addingTimeInterval(60)
        guard value.isFinite, value >= 0, date <= upper else { throw StoreError.message("日期超出可记录范围") }
    }

    private static func demoData(deviceID: String) -> PayData {
        var data = PayData()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let today = calendar.startOfDay(for: Date())
        let rule = PaySettings(effectiveFrom: calendar.date(byAdding: .month, value: -1, to: today)!, monthlyBase: 8000)
        data.settings = [rule]
        data.hasCompletedSetup = true
        if let entry = try? PayEngine.attendance(on: Date(), settings: rule, deviceID: deviceID, among: []) {
            data.entries = [entry]
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM"
        data.salaryMonths = [SalaryMonth(id: formatter.string(from: Date()), expectedCents: 800_000,
                                          payments: [SalaryPayment(amountCents: 300_000, paidAt: Date(), note: "演示到账")], note: "演示账本")]
        return data
    }
}

private enum StoreError: LocalizedError {
    case message(String)
    case unsupportedVersion
    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .unsupportedVersion: return "数据版本较新，请更新应用后再打开"
        }
    }
}
