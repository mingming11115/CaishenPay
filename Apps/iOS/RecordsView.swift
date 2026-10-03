import SwiftUI
import WorkPayCore

struct RecordsView: View {
    @EnvironmentObject private var store: PayStore
    @State private var editor: RecordEditorRequest?
    @State private var deleting: WorkEntry?
    @State private var showActiveMessage = false
    @State private var filter = RecordFilter.all

    private var records: [WorkEntry] {
        store.data.entries.filter { $0.deletedAt == nil }.sorted { $0.start > $1.start }
    }

    private var groups: [RecordDay] {
        let visible = records.filter { filter.includes($0) }
        return Dictionary(grouping: visible, by: { RecordFormatting.dayKey($0) })
            .map { RecordDay(id: $0.key, entries: $0.value.sorted { $0.start > $1.start }) }
            .sorted { $0.id > $1.id }
    }

    var body: some View {
        List {
            Section {
                Picker("记录类型", selection: $filter) {
                    ForEach(RecordFilter.allCases) { value in
                        Text(value.rawValue).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("records.filter")
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowBackground(Color.white)

            if let active = store.activeEntry {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("\(active.kind.title)正在计时", systemImage: "clock")
                                .font(PayTheme.font(15, weight: .semibold))
                            Spacer(minLength: 8)
                            Button("结束计时") { store.stop() }
                                .font(PayTheme.font(14, weight: .medium))
                                .foregroundStyle(PayTheme.cinnabar)
                                .buttonStyle(.borderless)
                        }
                        Text("结束计时后可补录或修正记录")
                            .font(PayTheme.font(13)).foregroundStyle(PayTheme.muted)
                    }.padding(.vertical, 4)
                }.listRowBackground(Color.white)
            }
            if !store.conflictIDs.isEmpty {
                Section {
                    Label("有 \(store.conflictIDs.count) 条重叠记录需要修正", systemImage: "exclamationmark.circle")
                        .foregroundStyle(PayTheme.cinnabar)
                    Text("所有冲突记录暂不计入收入。请核对两台设备的记录，修正时段或删除重复项。")
                        .font(PayTheme.font(14)).foregroundStyle(PayTheme.muted)
                }.listRowBackground(Color.white)
            }
            if let error = store.errorMessage {
                Section { Text(error).foregroundStyle(PayTheme.cinnabar) }.listRowBackground(Color.white)
            }

            if groups.isEmpty {
                Section {
                    ContentUnavailableView(filter.emptyTitle, systemImage: "calendar.badge.clock",
                                           description: Text("点击右上角「补录」添加记录。"))
                }.listRowBackground(Color.white)
            } else {
                ForEach(groups) { group in
                    Section {
                    ForEach(group.entries) { record in
                        Button { open(record) } label: {
                            if record.end == nil {
                                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                                    RecordRow(entry: record, hasConflict: store.conflictIDs.contains(record.id), now: timeline.date)
                                }
                            } else {
                                RecordRow(entry: record, hasConflict: store.conflictIDs.contains(record.id), now: Date())
                            }
                        }.buttonStyle(.plain)
                        .accessibilityHint("轻点修正记录")
                        .swipeActions {
                            Button("删除", role: .destructive) { deleting = record }
                        }
                    }
                    } header: {
                        HStack {
                            Text(group.title)
                            Spacer()
                            Text("\(group.entries.count) 条")
                        }
                        .font(PayTheme.font(13, weight: .medium))
                        .foregroundStyle(PayTheme.muted)
                        .textCase(nil)
                    }
                    .listRowBackground(Color.white)
                    .listRowSeparatorTint(PayTheme.line.opacity(0.5))
                }
            }
        }
        .listStyle(.insetGrouped).font(PayTheme.font(17)).foregroundStyle(PayTheme.ink)
        .contentMargins(.top, 12, for: .scrollContent)
        .tint(PayTheme.cinnabar).scrollContentBackground(.hidden).background(Color.white)
        .navigationTitle("加班与出勤").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if store.activeEntry != nil { showActiveMessage = true }
                    else { editor = RecordEditorRequest(entry: nil) }
                } label: { Label("补录", systemImage: "plus") }
                .accessibilityIdentifier("records.add")
            }
        }
        .sheet(item: $editor) { request in
            NavigationStack { RecordEditor(entry: request.entry).environmentObject(store) }
        }
        .alert("请先结束当前计时", isPresented: $showActiveMessage) {
            Button("知道了", role: .cancel) {}
        } message: { Text("结束计时后，就可以补录或修正记录。") }
        .alert("删除这条记录？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { entry in
            Button("删除记录", role: .destructive) { store.deleteEntry(entry.id); deleting = nil }
            Button("取消", role: .cancel) { deleting = nil }
        } message: { entry in
            Text("\(RecordFormatting.date(entry.start, rule: entry.settings))的\(entry.kind.title)将从计薪中移除。")
        }
    }

    private func open(_ entry: WorkEntry) {
        if store.activeEntry != nil || entry.end == nil { showActiveMessage = true }
        else { editor = RecordEditorRequest(entry: entry) }
    }
}

private enum RecordFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case overtime = "加班"
    case attendance = "出勤"

    var id: String { rawValue }
    var emptyTitle: String { self == .all ? "还没有工作记录" : "还没有\(rawValue)记录" }
    func includes(_ entry: WorkEntry) -> Bool {
        switch self {
        case .all: return true
        case .overtime: return entry.kind != .regular
        case .attendance: return entry.kind == .regular
        }
    }
}

private struct RecordDay: Identifiable {
    let id: String
    let entries: [WorkEntry]
    var title: String {
        guard let first = entries.first else { return "" }
        return RecordFormatting.date(first.start, rule: first.settings)
    }
}

private struct RecordRow: View {
    let entry: WorkEntry
    let hasConflict: Bool
    let now: Date

    private var income: Int64 {
        guard !hasConflict else { return 0 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: entry.settings.timeZoneID) ?? MainlandWorkCalendar.calendar.timeZone
        var total: Int64 = 0
        var day = calendar.startOfDay(for: entry.start)
        let end = min(entry.end ?? now, now)
        // Use the same per-day engine as the ledger, including historical shifts
        // and breaks. An unfinished timer can span more than one civil date.
        repeat {
            let value = PayEngine.summary(on: day, asOf: now, entries: [entry], calendar: calendar).totalCents
            let sum = total.addingReportingOverflow(value)
            total = sum.overflow ? Int64.max : sum.partialValue
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            day = next
        } while day < end
        return total
    }

    private var title: String {
        entry.kind == .regular ? (entry.isAttendance ? "上班出勤" : "上班 · 旧版计时") : entry.kind.title
    }

    private var duration: String {
        entry.isAttendance ? "出勤 1 天" : RecordFormatting.duration((entry.end ?? now).timeIntervalSince(entry.start))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(PayTheme.font(17, weight: .semibold))
                    if entry.kind != .regular {
                        Text("\(NSDecimalNumber(decimal: entry.settings.multiplier(for: entry.kind)).stringValue) 倍")
                            .font(PayTheme.font(12, weight: .medium))
                            .foregroundStyle(PayTheme.cinnabar)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(PayTheme.cinnabar.opacity(0.07), in: Capsule())
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(hasConflict ? "暂不计薪" : entry.end == nil ? "当前收入" : "本次收入")
                        .font(PayTheme.font(12)).foregroundStyle(PayTheme.muted)
                    Text(hasConflict ? "—" : PayDisplay.money(income))
                        .font(PayTheme.font(23, weight: .semibold))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                        .foregroundStyle(entry.kind == .regular ? PayTheme.ink : PayTheme.cinnabar)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack {
                    timing
                    Spacer(minLength: 12)
                    recordDetail
                }
                VStack(alignment: .leading, spacing: 6) {
                    timing
                    recordDetail
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if hasConflict {
                Label("时段重叠 · 暂不计薪", systemImage: "exclamationmark.circle")
                    .font(PayTheme.font(13)).foregroundStyle(PayTheme.cinnabar)
            }
            if entry.needsTypeReview {
                Label("跨日加班 · 请确认当天类型", systemImage: "calendar.badge.exclamationmark")
                    .font(PayTheme.font(13)).foregroundStyle(PayTheme.cinnabar)
            }
            if entry.end == nil {
                Label("正在计时", systemImage: "clock.badge")
                    .font(PayTheme.font(13)).foregroundStyle(PayTheme.cinnabar)
            }
        }.padding(.vertical, 12)
    }

    private var timing: some View {
        Label(entry.isAttendance ? duration : RecordFormatting.interval(entry),
              systemImage: entry.isAttendance ? "calendar" : "clock")
            .labelStyle(.titleAndIcon)
            .font(PayTheme.font(15)).foregroundStyle(PayTheme.ink).fixedSize()
    }

    private var recordDetail: some View {
        HStack(spacing: 8) {
            Text(entry.isAttendance ? "" : duration)
                .font(PayTheme.font(14)).monospacedDigit()
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                .accessibilityHidden(true)
        }.foregroundStyle(PayTheme.muted).fixedSize()
    }
}

private struct RecordEditor: View {
    @EnvironmentObject private var store: PayStore
    @Environment(\.dismiss) private var dismiss
    let entry: WorkEntry?
    @State private var start: Date
    @State private var end: Date
    @State private var kind: WorkKind
    @State private var useDailyPay: Bool
    @State private var confirmedType: Bool
    @State private var inputError: String?

    init(entry: WorkEntry?) {
        self.entry = entry
        _start = State(initialValue: entry?.start ?? Date().addingTimeInterval(-3600))
        _end = State(initialValue: entry?.end ?? Date())
        _kind = State(initialValue: entry?.kind ?? .weekday)
        _useDailyPay = State(initialValue: entry?.kind != .regular || entry?.isAttendance == true)
        _confirmedType = State(initialValue: !(entry?.needsTypeReview ?? false))
    }
    private var rule: PaySettings? {
        if let entry { return entry.settings }
        let ruleDate = dailyMode ? MainlandWorkCalendar.calendar.startOfDay(for: start) : start
        guard var rule = PayEngine.settings(on: ruleDate, in: store.data.settings) else { return nil }
        if let days = try? MainlandWorkCalendar.workdays(inMonthOf: start) { rule.paidDays = Decimal(days) }
        return rule
    }
    private var calendar: Calendar {
        if dailyMode { return MainlandWorkCalendar.calendar }
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: rule?.timeZoneID ?? "Asia/Shanghai")!
        return value
    }
    private var dailyMode: Bool { kind == .regular && useDailyPay }
    private var crossesMidnight: Bool { !calendar.isDate(start, inSameDayAs: end.addingTimeInterval(-0.001)) && end > start }

    var body: some View {
        Form {
            Section(dailyMode ? "出勤日期" : "记录时段") {
                if dailyMode {
                    DatePicker("日期", selection: $start, in: ...Date(), displayedComponents: .date)
                    Text("正常上班记一天，无需填写上下班时间。")
                } else {
                DatePicker("开始", selection: $start, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                DatePicker("结束", selection: $end, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                if end > start {
                    LabeledContent("记录跨度", value: RecordFormatting.duration(end.timeIntervalSince(start)))
                        .font(PayTheme.font(14)).foregroundStyle(PayTheme.muted)
                }
                }
            }.listRowBackground(Color.white)
            Section {
                Picker("工作类型", selection: $kind) {
                    ForEach(WorkKind.allCases) { type in Text(type.title).tag(type) }
                }
                if entry?.kind == .regular, entry?.isAttendance == false, kind == .regular {
                    Toggle("改为按天出勤", isOn: $useDailyPay)
                        .accessibilityIdentifier("record.dailyPay")
                    if useDailyPay {
                        Text("保存后此条记录改为1天出勤，收入按月薪÷当月工作日计算；取消则保留原计时记录。")
                            .font(PayTheme.font(14)).foregroundStyle(PayTheme.cinnabar)
                    }
                }
                if entry?.needsTypeReview == true, kind != .regular {
                    Toggle("已确认此日期的加班类型", isOn: $confirmedType)
                }
                Text(kind == .regular ? "正常上班按天计薪；旧版计时记录保留原算法。" : "加班按所选倍率连续计薪。如有中途休息，请将休息前后分别保存为两条记录。")
                    .font(PayTheme.font(14)).foregroundStyle(PayTheme.muted)
            } header: { Text("类型与休息") }
              footer: { Text("请按实际班表选择，加班类型不会根据日历自动判断。") }
            .listRowBackground(Color.white)

            Section {
                if let rule {
                    if dailyMode {
                        if let days = try? PayEngine.attendanceDays(on: start, preserving: entry) {
                            LabeledContent("当月工作日", value: "\(days) 天")
                            LabeledContent("每日收入", value: RecordFormatting.money(rule.monthlyBase / Decimal(days)))
                        } else {
                            Text("所选年份的调休日历尚未收录")
                        }
                    } else {
                        LabeledContent("基准时薪", value: RecordFormatting.money(rule.hourlyRate))
                        LabeledContent("本次倍率", value: NSDecimalNumber(decimal: rule.multiplier(for: kind)).stringValue + " 倍")
                    }
                    LabeledContent("班次时区", value: rule.timeZoneID)
                    Text(entry == nil ? "使用开始时间当日已生效的工资规则。" : "编辑历史记录继续使用此记录保存的工资与班次，不会自动改成当前设置。")
                        .font(PayTheme.font(14)).foregroundStyle(PayTheme.muted)
                } else {
                    Text("开始时间之前没有生效的工资规则。请先在设置中保存对应日期的规则。")
                        .foregroundStyle(PayTheme.cinnabar)
                }
                if !dailyMode && crossesMidnight {
                    Text(kind == .regular ? "跨午夜记录会按日期拆分保存。" : "跨午夜记录会按日期拆分保存；次日起的加班类型需要在记录列表中逐日确认。")
                        .font(PayTheme.font(14)).foregroundStyle(PayTheme.cinnabar)
                }
            } header: { Text(entry == nil ? "计薪规则" : "历史规则快照") }
            .listRowBackground(Color.white)
            if let message = inputError ?? store.errorMessage {
                Section { Text(message).foregroundStyle(PayTheme.cinnabar) }.listRowBackground(Color.white)
            }
        }
        .font(PayTheme.font(17)).foregroundStyle(PayTheme.ink)
        .tint(PayTheme.cinnabar).scrollContentBackground(.hidden).background(Color.white)
        .environment(\.timeZone, calendar.timeZone)
        .navigationTitle(entry == nil ? "补录工作" : "修正记录").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).accessibilityIdentifier("record.save") }
        }
    }

    private func save() {
        inputError = nil
        guard store.activeEntry == nil else { inputError = "请先结束正在进行的计时，再修正记录。"; return }
        if dailyMode {
            store.saveAttendance(on: start, replacing: entry)
            if store.errorMessage == nil { dismiss() }
            return
        }
        guard end > start else { inputError = "结束时间必须晚于开始时间。"; return }
        guard end <= Date() else { inputError = "工作记录不能使用未来时间。"; return }
        guard let rule else { inputError = "此开始时间没有可用的工资规则，请先保存对应设置。"; return }
        guard entry?.needsTypeReview != true || kind == .regular || confirmedType else {
            inputError = "请确认此日期的加班类型后再保存。"; return
        }
        var updated = entry ?? WorkEntry(start: start, end: end, kind: kind, settings: rule, deviceID: store.deviceID)
        if entry?.start != start || entry?.kind != kind { updated.regularShiftAnchor = nil }
        if let days = entry?.attendanceWorkdays { updated.settings.paidDays = Decimal(days) }
        updated.attendanceWorkdays = nil
        updated.start = start; updated.end = end; updated.kind = kind; updated.needsTypeReview = false
        if entry == nil {
            guard let days = try? MainlandWorkCalendar.workdays(inMonthOf: start) else {
                inputError = "该年份的调休日历尚未收录"; return
            }
            updated.settings.paidDays = Decimal(days)
        }
        store.saveEntry(updated)
        if store.errorMessage == nil { dismiss() }
    }
}

private struct RecordEditorRequest: Identifiable {
    let id = UUID()
    let entry: WorkEntry?
}
private enum RecordFormatting {
    static func dayKey(_ entry: WorkEntry) -> String { formatted(entry.start, rule: entry.settings, pattern: "yyyy-MM-dd") }
    static func date(_ date: Date, rule: PaySettings) -> String { formatted(date, rule: rule, pattern: "yyyy年M月d日 EEEE") }
    static func interval(_ entry: WorkEntry) -> String {
        let start = formatted(entry.start, rule: entry.settings, pattern: "HH:mm")
        guard let end = entry.end else { return start + " — 现在" }
        let sameDay = formatted(entry.start, rule: entry.settings, pattern: "yyyy-MM-dd") == formatted(end, rule: entry.settings, pattern: "yyyy-MM-dd")
        return start + " — " + formatted(end, rule: entry.settings, pattern: sameDay ? "HH:mm" : "M月d日 HH:mm")
    }
    static func formatted(_ date: Date, rule: PaySettings, pattern: String) -> String {
        let format = DateFormatter(); format.calendar = Calendar(identifier: .gregorian)
        format.locale = Locale(identifier: "zh_CN"); format.timeZone = TimeZone(identifier: rule.timeZoneID)
        format.dateFormat = pattern; return format.string(from: date)
    }
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        return "\(minutes / 60) 小时 \(minutes % 60) 分"
    }
    static func money(_ amount: Decimal) -> String {
        let format = NumberFormatter(); format.locale = Locale(identifier: "zh_CN")
        format.numberStyle = .currency; format.currencyCode = "CNY"; format.minimumFractionDigits = 2; format.maximumFractionDigits = 2
        return format.string(from: NSDecimalNumber(decimal: amount)) ?? "¥0.00"
    }
}
