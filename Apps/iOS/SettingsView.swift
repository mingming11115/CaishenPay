import SwiftUI
import WorkPayCore

struct SettingsView: View {
    @EnvironmentObject private var store: PayStore
    let onboarding: Bool
    @State private var draft = SettingsDraft()
    @State private var loaded = false
    @State private var message: String?
    @State private var inputError: String?

    init(onboarding: Bool = false) { self.onboarding = onboarding }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: draft.timeZoneID) ?? TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    var body: some View {
        Form {
            if onboarding {
                Section {
                    Text("先定好一份属于你的工资规则")
                        .font(PayTheme.font(23, weight: .semibold))
                    Text("填写并确认月薪后开始记薪。今日折算收入仅为估算，到账另记入工资账本。")
                        .font(PayTheme.font(15)).foregroundStyle(PayTheme.muted)
                }.listRowBackground(Color.white)
            }
            Section {
                numberField("月 base（元）", text: $draft.base, placeholder: "请输入你的月薪")
                if let days = try? MainlandWorkCalendar.workdays(inMonthOf: draft.effectiveFrom) {
                    LabeledContent("当月工作日", value: "\(days) 天 · 自动读取")
                    if let base = SettingsNumbers.decimal(draft.base) {
                        LabeledContent("每日正常收入", value: SettingsNumbers.money(base / Decimal(days)))
                    }
                } else {
                    Text("所选年份的节假日及调休安排尚未收录，请更新日历数据。")
                        .foregroundStyle(PayTheme.cinnabar)
                }
                numberField("每日标准小时（加班折算）", text: $draft.hours, placeholder: "8")
                if let base = SettingsNumbers.decimal(draft.base),
                   let workdays = try? MainlandWorkCalendar.workdays(inMonthOf: draft.effectiveFrom), workdays > 0,
                   let hours = SettingsNumbers.decimal(draft.hours), hours > 0 {
                    LabeledContent("折算基准时薪", value: SettingsNumbers.money(base / Decimal(workdays) / hours) + " / 小时")
                        .font(PayTheme.font(14)).foregroundStyle(PayTheme.muted)
                }
            } header: { Text("工资基准") }
              footer: { Text("正常收入 = 月薪 ÷ 当月工作日。按中国大陆节假日及调休自动统计，内置2026年日历；加班时薪再除以每日标准小时。") }
            .listRowBackground(Color.white)

            Section {
                numberField("工作日加班倍率", text: $draft.weekday, placeholder: "1.5")
                numberField("休息日加班倍率", text: $draft.weekend, placeholder: "2")
                numberField("节假日加班倍率", text: $draft.holiday, placeholder: "3")
            } header: { Text("加班倍率") }
              footer: { Text("加班类型由你逐次确认，以适应调休和个人班表。") }
            .listRowBackground(Color.white)

            Section {
                DatePicker("规则生效日期", selection: $draft.effectiveFrom, displayedComponents: .date)
                Text("新规则从所选日期起供新记录使用。已保存记录保留原规则，修正记录时也不会自动换成新工资。")
                    .font(PayTheme.font(14)).foregroundStyle(PayTheme.muted)
                if store.activeEntry != nil {
                    Text("保存今天或更早生效的规则，会先结束当前计时并保留旧规则。")
                        .font(PayTheme.font(14)).foregroundStyle(PayTheme.cinnabar)
                }
            } header: { Text("生效与历史") }
            .listRowBackground(Color.white)

            if let error = inputError ?? store.errorMessage {
                Section { Text(error).foregroundStyle(PayTheme.cinnabar).accessibilityLabel("保存失败，" + error) }
                    .listRowBackground(Color.white)
            }
            if let message {
                Section { Text(message).foregroundStyle(PayTheme.cinnabar) }.listRowBackground(Color.white)
            }
            Section {
                Button(action: save) {
                    Text(onboarding ? "确认设置，开始记薪" : "保存为新的工资规则")
                        .font(PayTheme.font(17, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 32)
                }.accessibilityIdentifier("settings.save")
            }.listRowBackground(Color.white)

            if !store.data.settings.isEmpty {
                Section("已保存的规则") {
                    ForEach(store.data.settings.sorted { $0.effectiveFrom > $1.effectiveFrom }) { rule in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(SettingsNumbers.date(rule.effectiveFrom, timeZoneID: rule.timeZoneID) + " 起生效")
                                .font(PayTheme.font(16, weight: .semibold))
                            Text("月 base " + SettingsNumbers.money(rule.monthlyBase))
                            Text("正常上班按当月日历记薪 · 加班另算")
                                .font(PayTheme.font(13)).foregroundStyle(PayTheme.muted)
                        }.padding(.vertical, 4)
                    }
                }.listRowBackground(Color.white)
            }
        }
        .font(PayTheme.font(17)).foregroundStyle(PayTheme.ink)
        .tint(PayTheme.cinnabar).scrollContentBackground(.hidden).background(Color.white)
        .environment(\.timeZone, calendar.timeZone)
        .navigationTitle(onboarding ? "欢迎记薪" : "工资设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func numberField(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(PayTheme.font(15)).foregroundStyle(PayTheme.muted)
            TextField(placeholder, text: text).keyboardType(.decimalPad)
                .font(PayTheme.font(20)).accessibilityLabel(title)
        }.padding(.vertical, 3)
    }
    private func load() {
        guard !loaded else { return }; loaded = true
        if let rule = store.currentSettings ?? store.data.settings.max(by: { $0.effectiveFrom < $1.effectiveFrom }) {
            draft.base = SettingsNumbers.plain(rule.monthlyBase)
            draft.hours = SettingsNumbers.plain(rule.dailyHours)
            draft.weekday = SettingsNumbers.plain(rule.weekdayMultiplier)
            draft.weekend = SettingsNumbers.plain(rule.weekendMultiplier); draft.holiday = SettingsNumbers.plain(rule.holidayMultiplier)
            draft.startMinute = rule.startMinute; draft.endMinute = rule.endMinute
            draft.breakStartMinute = rule.breakStartMinute; draft.breakEndMinute = rule.breakEndMinute
            draft.timeZoneID = "Asia/Shanghai"
        }
        draft.effectiveFrom = calendar.startOfDay(for: Date())
    }
    private func save() {
        inputError = nil; message = nil
        guard let base = SettingsNumbers.decimal(draft.base),
              let hours = SettingsNumbers.decimal(draft.hours), let weekday = SettingsNumbers.decimal(draft.weekday),
              let weekend = SettingsNumbers.decimal(draft.weekend), let holiday = SettingsNumbers.decimal(draft.holiday) else {
            inputError = "请填写完整数字，使用小数点，不使用千位分隔符。"; return
        }
        guard let workdays = try? MainlandWorkCalendar.workdays(inMonthOf: draft.effectiveFrom) else {
            inputError = "该年份的调休日历尚未收录，请更新日历数据后保存。"; return
        }
        let rule = PaySettings(effectiveFrom: calendar.startOfDay(for: draft.effectiveFrom), monthlyBase: base,
                               paidDays: Decimal(workdays), dailyHours: hours, weekdayMultiplier: weekday,
                               weekendMultiplier: weekend, holidayMultiplier: holiday,
                               startMinute: draft.startMinute, endMinute: draft.endMinute,
                               breakStartMinute: draft.breakStartMinute, breakEndMinute: draft.breakEndMinute,
                               timeZoneID: draft.timeZoneID)
        store.saveSettings(rule)
        if store.errorMessage == nil { message = "新规则已保存。已有记录继续使用原来的工资快照。" }
    }
}

private struct SettingsDraft {
    var base = ""
    var hours = "8"
    var weekday = "1.5"
    var weekend = "2"
    var holiday = "3"
    var startMinute = 540
    var endMinute = 1080
    var breakStartMinute = 720
    var breakEndMinute = 780
    var timeZoneID = "Asia/Shanghai"
    var effectiveFrom = Date()
}

private enum SettingsNumbers {
    static func decimal(_ text: String) -> Decimal? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: "^(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)$", options: .regularExpression) != nil else { return nil }
        guard let amount = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), !amount.isNaN else { return nil }
        return amount
    }
    static func plain(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }
    static func money(_ value: Decimal) -> String {
        let format = NumberFormatter(); format.locale = Locale(identifier: "zh_CN")
        format.numberStyle = .currency; format.currencyCode = "CNY"; format.minimumFractionDigits = 2; format.maximumFractionDigits = 2
        return format.string(from: NSDecimalNumber(decimal: value)) ?? "¥0.00"
    }
    static func date(_ value: Date, timeZoneID: String) -> String {
        let format = DateFormatter(); format.calendar = Calendar(identifier: .gregorian)
        format.locale = Locale(identifier: "zh_CN"); format.timeZone = TimeZone(identifier: timeZoneID)
        format.dateFormat = "yyyy年M月d日"; return format.string(from: value)
    }
}
