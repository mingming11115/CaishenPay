import SwiftUI
import WorkPayCore

struct LedgerView: View {
    @EnvironmentObject private var store: PayStore
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var monthNumber = Calendar.current.component(.month, from: Date())
    @State private var section = LedgerSection.payments
    @State private var mode = LedgerEntryMode.expected
    @State private var expectedText = ""
    @State private var remainingText = ""
    @State private var note = ""
    @State private var inputError: String?
    @State private var success: String?
    @State private var paymentEditor: PaymentEditorRequest?
    @State private var paymentToDelete: SalaryPayment?
    @State private var loaded = false
    @State private var showEditor = false
    @State private var showHistory = false

    private var monthID: String { String(format: "%04d-%02d", year, monthNumber) }
    private var monthTitle: String { String(format: "%d 年 %d 月", year, monthNumber) }
    private var month: SalaryMonth? { store.month(monthID) }
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: store.currentSettings?.timeZoneID ?? "Asia/Shanghai")!
        return value
    }
    // Keep a month-centred instant when historical settings use a different zone.
    private var selectedDate: Date { calendar.date(from: DateComponents(year: year, month: monthNumber, day: 15, hour: 12))! }
    private var totalOutstanding: Int64 {
        store.data.salaryMonths.reduce(0) { total, month in
            let result = total.addingReportingOverflow(month.outstandingCents)
            return result.overflow ? Int64.max : result.partialValue
        }
    }
    private var proposedExpected: Int64? {
        guard let value = LedgerNumbers.cents(mode == .expected ? expectedText : remainingText) else { return nil }
        if mode == .expected { return value }
        let result = (month?.receivedCents ?? 0).addingReportingOverflow(value)
        guard !result.overflow, result.partialValue <= PayEngine.maximumAmountCents else { return nil }
        return result.partialValue
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 20) {
                    monthSelector
                    Picker("账本内容", selection: $section) {
                        ForEach(LedgerSection.allCases) { item in Text(item.rawValue).tag(item) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("ledger.section")
                }.padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.white)

            if section == .payments {
                Section {
                    if let month { salaryOverview(month) }
                    else { emptyMonth }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.white)

                if let month {
                    Section {
                        HStack(spacing: 12) {
                            Button { paymentEditor = PaymentEditorRequest(payment: nil) } label: {
                                Text("登记到账")
                            }
                            .buttonStyle(CinnabarButtonStyle())
                            .accessibilityIdentifier("ledger.addPayment")
                            Button { showEditor = true } label: { Text("调整应收") }
                                .buttonStyle(CinnabarButtonStyle(filled: false))
                                .accessibilityIdentifier("ledger.edit")
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.white)

                    Section {
                        if month.payments.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("还没有到账记录").font(PayTheme.font(16, weight: .medium))
                                Text("收到工资后，点击「登记到账」。")
                                    .font(PayTheme.font(13)).foregroundStyle(PayTheme.muted)
                            }.padding(.vertical, 12)
                        }
                        ForEach(month.payments.sorted { $0.paidAt > $1.paidAt }) { payment in
                            Button { paymentEditor = PaymentEditorRequest(payment: payment) } label: {
                                paymentRow(payment)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("轻点修正这笔到账")
                            .swipeActions {
                                Button("删除", role: .destructive) { paymentToDelete = payment }
                            }
                        }
                    } header: {
                        HStack {
                            Text("到账明细")
                            Spacer()
                            Text("\(month.payments.count) 笔")
                        }.textCase(nil)
                    }
                    .listRowSeparatorTint(PayTheme.line.opacity(0.5))
                    .listRowBackground(Color.white)
                }
            } else {
                IncomeCalendarView(monthDate: selectedDate, calendar: calendar)
            }

            if let message = store.errorMessage, !showEditor {
                Section { Text(message).foregroundStyle(PayTheme.cinnabar) }.listRowBackground(Color.white)
            }
            if let success {
                Section {
                    Label(success, systemImage: "checkmark.circle")
                        .font(PayTheme.font(14)).foregroundStyle(PayTheme.muted)
                }.listRowBackground(Color.white)
            }
        }
        .listStyle(.insetGrouped).font(PayTheme.font(17)).foregroundStyle(PayTheme.ink)
        .contentMargins(.top, 8, for: .scrollContent)
        .tint(PayTheme.cinnabar).scrollContentBackground(.hidden).background(Color.white)
        .navigationTitle("工资账本").navigationBarTitleDisplayMode(.inline)
        .environment(\.timeZone, calendar.timeZone)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("历史") { showHistory = true }
                    .accessibilityLabel("历史工资账本")
                    .accessibilityIdentifier("ledger.history")
            }
        }
        .onAppear {
            if !loaded {
                loaded = true
                year = calendar.component(.year, from: Date())
                monthNumber = calendar.component(.month, from: Date())
                loadMonth()
            }
        }
        .onChange(of: monthID) { _, _ in loadMonth(); showEditor = false }
        .onChange(of: month?.receivedCents) { previous, _ in
            // Refresh an untouched balance while preserving unsaved user drafts.
            guard let previous, let month,
                  remainingText == LedgerNumbers.input(max(0, month.expectedCents - previous)) else { return }
            remainingText = LedgerNumbers.input(month.outstandingCents)
        }
        .sheet(isPresented: $showEditor) { expectedEditor }
        .sheet(isPresented: $showHistory) { historyView }
        .sheet(item: $paymentEditor) { request in
            NavigationStack { PaymentEditor(monthID: monthID, payment: request.payment).environmentObject(store) }
        }
        .alert("删除这笔到账？", isPresented: Binding(get: { paymentToDelete != nil }, set: { if !$0 { paymentToDelete = nil } }), presenting: paymentToDelete) { payment in
            Button("删除到账", role: .destructive) { deletePayment(payment) }
            Button("取消", role: .cancel) { paymentToDelete = nil }
        } message: { payment in
            Text("将移除 \(LedgerNumbers.money(payment.amountCents))，所选月份的待收金额会重新计算。")
        }
    }

    private var monthSelector: some View {
        HStack {
            Button { moveMonth(-1) } label: {
                Image(systemName: "chevron.left").frame(width: 40, height: 40)
            }
            .disabled(year == 1900 && monthNumber == 1)
            .accessibilityLabel("上个月").accessibilityIdentifier("ledger.previousMonth")
            Spacer(minLength: 4)
            Menu {
                Picker("年份", selection: $year) {
                    ForEach(1900...2199, id: \.self) { value in Text(String(value) + " 年").tag(value) }
                }.accessibilityIdentifier("ledger.year")
                Picker("月份", selection: $monthNumber) {
                    ForEach(1...12, id: \.self) { value in Text("\(value) 月").tag(value) }
                }.accessibilityIdentifier("ledger.month")
            } label: {
                HStack(spacing: 8) {
                    Text(monthTitle).font(PayTheme.font(22, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                }.foregroundStyle(PayTheme.ink)
            }
            .accessibilityIdentifier("ledger.selectMonth")
            Spacer(minLength: 4)
            Button { moveMonth(1) } label: {
                Image(systemName: "chevron.right").frame(width: 40, height: 40)
            }
            .disabled(year == 2199 && monthNumber == 12)
            .accessibilityLabel("下个月").accessibilityIdentifier("ledger.nextMonth")
        }.buttonStyle(.borderless)
    }

    private func salaryOverview(_ month: SalaryMonth) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("还未到账").font(PayTheme.font(14)).foregroundStyle(PayTheme.muted)
                    Spacer()
                    Text(month.outstandingCents > 0 ? "待收款" : month.overpaidCents > 0 ? "超额到账" : "已结清")
                        .font(PayTheme.font(12, weight: .medium))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(PayTheme.cinnabar.opacity(0.07), in: Capsule())
                }
                Text(LedgerNumbers.money(month.outstandingCents))
                    .font(PayTheme.font(40, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(PayTheme.cinnabar)
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .accessibilityLabel("本月还未到账 " + LedgerNumbers.money(month.outstandingCents))
                    .accessibilityIdentifier("ledger.outstanding")
            }
            HStack(spacing: 20) {
                amountColumn("应收工资", cents: month.expectedCents)
                Rectangle().fill(PayTheme.line.opacity(0.6)).frame(width: 0.5, height: 40)
                amountColumn("已到账", cents: month.receivedCents)
            }
            if month.overpaidCents > 0 {
                Text("到账已超出应收 " + LedgerNumbers.money(month.overpaidCents))
                    .font(PayTheme.font(14)).foregroundStyle(PayTheme.cinnabar)
            }
            if !month.note.isEmpty {
                Text(month.note).font(PayTheme.font(13)).foregroundStyle(PayTheme.muted)
            }
        }.padding(.vertical, 8)
    }

    private func amountColumn(_ title: String, cents: Int64) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(PayTheme.font(14)).foregroundStyle(PayTheme.muted)
            Text(LedgerNumbers.money(cents)).font(PayTheme.font(21, weight: .medium))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyMonth: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("这个月还没有工资账本").font(PayTheme.font(21, weight: .semibold))
            Button("填写应收工资") { showEditor = true }
                .buttonStyle(CinnabarButtonStyle())
                .accessibilityIdentifier("ledger.edit")
        }.padding(.vertical, 12)
    }

    private func paymentRow(_ payment: SalaryPayment) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text(LedgerNumbers.date(payment.paidAt, timeZone: calendar.timeZone))
                    .font(PayTheme.font(15, weight: .medium))
                if !payment.note.isEmpty {
                    Text(payment.note).font(PayTheme.font(13)).foregroundStyle(PayTheme.muted)
                }
            }
            Spacer(minLength: 4)
            Text("+" + LedgerNumbers.money(payment.amountCents))
                .font(PayTheme.font(20, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.65).layoutPriority(1)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PayTheme.muted).accessibilityHidden(true)
        }.padding(.vertical, 12)
    }

    private var expectedEditor: some View {
        NavigationStack {
            Form {
                Section { LabeledContent("工资所属月份", value: monthTitle) }
                    .listRowBackground(Color.white)
                Section {
                    Picker("录入方式", selection: $mode) {
                        ForEach(LedgerEntryMode.allCases) { value in Text(value.title).tag(value) }
                    }.pickerStyle(.segmented)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(mode == .expected ? "全部应收（元）" : "剩余未到账（元）")
                            .font(PayTheme.font(14)).foregroundStyle(PayTheme.muted)
                        TextField("请输入金额，最多两位小数", text: mode == .expected ? $expectedText : $remainingText)
                            .keyboardType(.decimalPad).font(PayTheme.font(24))
                            .accessibilityLabel(mode == .expected ? "应收工资金额" : "剩余未到账金额")
                    }.padding(.vertical, 5)
                    if mode == .remaining, let proposedExpected {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("应收将调整为 " + LedgerNumbers.money(proposedExpected))
                                .font(PayTheme.font(16, weight: .medium)).foregroundStyle(PayTheme.cinnabar)
                            Text("已到账 \(LedgerNumbers.money(month?.receivedCents ?? 0)) ＋ 剩余待收 \(LedgerNumbers.money(LedgerNumbers.cents(remainingText) ?? 0))")
                                .font(PayTheme.font(13)).foregroundStyle(PayTheme.muted)
                        }
                    }
                    TextField("备注：税费、扣款、补发等", text: $note, axis: .vertical).lineLimit(2...5)
                } header: { Text("工资金额") }
                .listRowBackground(Color.white)

                Section {
                    LedgerAmountRow(title: "基本工资＋已记加班", cents: store.estimatedMonth(selectedDate))
                    Button("使用估算金额") {
                        mode = .expected; expectedText = LedgerNumbers.input(store.estimatedMonth(selectedDate))
                        inputError = nil; success = nil
                    }
                } header: { Text("估算参考") }
                  footer: { Text("整月基本工资加已记录加班；税费、扣款和补发请自行调整，保存后生效。") }
                .listRowBackground(Color.white)
                if let message = inputError ?? store.errorMessage {
                    Section { Text(message).foregroundStyle(PayTheme.cinnabar) }.listRowBackground(Color.white)
                }
            }
            .font(PayTheme.font(17)).foregroundStyle(PayTheme.ink)
            .tint(PayTheme.cinnabar).scrollContentBackground(.hidden).background(Color.white)
            .navigationTitle(month == nil ? "建立工资账本" : "调整应收")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { showEditor = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: saveMonth).accessibilityIdentifier("ledger.save")
                }
            }
        }
    }

    private var historyView: some View {
        NavigationStack {
            List {
                if store.data.salaryMonths.isEmpty {
                    ContentUnavailableView("还没有历史账本", systemImage: "book.closed",
                                           description: Text("保存应收工资后，会按工资所属月份列在这里。"))
                        .listRowBackground(Color.white)
                } else {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("全部月份待收").font(PayTheme.font(14)).foregroundStyle(PayTheme.muted)
                            Text(LedgerNumbers.money(totalOutstanding))
                                .font(PayTheme.font(32, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(PayTheme.cinnabar).lineLimit(1).minimumScaleFactor(0.5)
                        }.padding(.vertical, 8)
                    }.listRowBackground(Color.white)
                    Section("已建立的工资账本") {
                        ForEach(store.data.salaryMonths.sorted { $0.id > $1.id }) { saved in
                            Button { selectMonth(saved.id) } label: {
                                VStack(alignment: .leading, spacing: 9) {
                                    HStack {
                                        Text(saved.id).font(PayTheme.font(18, weight: .semibold))
                                        Spacer()
                                        Text(saved.outstandingCents > 0 ? "待收 " + LedgerNumbers.money(saved.outstandingCents) : saved.overpaidCents > 0 ? "超额到账" : "已结清")
                                            .font(PayTheme.font(15, weight: .medium))
                                            .foregroundStyle(PayTheme.cinnabar)
                                        Image(systemName: "chevron.right").font(.system(size: 11))
                                    }
                                    Text("应收 \(LedgerNumbers.money(saved.expectedCents)) · 已到账 \(LedgerNumbers.money(saved.receivedCents))")
                                        .font(PayTheme.font(13)).foregroundStyle(PayTheme.muted)
                                }.padding(.vertical, 8)
                            }.buttonStyle(.plain)
                        }
                    }.listRowBackground(Color.white)
                }
            }
            .listStyle(.insetGrouped).font(PayTheme.font(17)).foregroundStyle(PayTheme.ink)
            .tint(PayTheme.cinnabar).scrollContentBackground(.hidden).background(Color.white)
            .navigationTitle("历史账本").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showHistory = false } } }
        }
    }

    private func moveMonth(_ offset: Int) {
        guard let date = calendar.date(byAdding: .month, value: offset, to: selectedDate) else { return }
        let newYear = calendar.component(.year, from: date)
        guard (1900...2199).contains(newYear) else { return }
        year = newYear; monthNumber = calendar.component(.month, from: date)
    }
    private func selectMonth(_ id: String) {
        let pieces = id.split(separator: "-")
        guard pieces.count == 2, let selectedYear = Int(pieces[0]), let selectedMonth = Int(pieces[1]) else { return }
        year = selectedYear; monthNumber = selectedMonth
        section = .payments; showHistory = false
    }
    private func loadMonth() {
        expectedText = month.map { LedgerNumbers.input($0.expectedCents) } ?? ""
        remainingText = month.map { LedgerNumbers.input($0.outstandingCents) } ?? ""
        note = month?.note ?? ""; inputError = nil; success = nil
    }
    private func saveMonth() {
        inputError = nil; success = nil
        guard let amount = proposedExpected else {
            inputError = "请输入不小于零的金额，最多两位小数且不超过一万亿元。"; return
        }
        var updated = month ?? SalaryMonth(id: monthID, expectedCents: amount)
        updated.expectedCents = amount; updated.note = note
        store.saveMonth(updated)
        if store.errorMessage == nil {
            loadMonth(); showEditor = false
            success = "\(monthTitle)应收已保存"
        }
    }
    private func deletePayment(_ payment: SalaryPayment) {
        guard var updated = month else { return }
        updated.payments.removeAll { $0.id == payment.id }
        store.saveMonth(updated); paymentToDelete = nil
        // The receivedCents observer refreshes only untouched balance drafts.
        if store.errorMessage == nil { success = "到账已删除，待收金额已更新" }
    }
}

private enum LedgerSection: String, CaseIterable, Identifiable {
    case payments = "工资到账"
    case income = "收入日历"
    var id: String { rawValue }
}

private struct PaymentEditor: View {
    @EnvironmentObject private var store: PayStore
    @Environment(\.dismiss) private var dismiss
    let monthID: String
    let payment: SalaryPayment?
    @State private var amount: String
    @State private var paidAt: Date
    @State private var note: String
    @State private var inputError: String?

    init(monthID: String, payment: SalaryPayment?) {
        self.monthID = monthID; self.payment = payment
        _amount = State(initialValue: payment.map { LedgerNumbers.input($0.amountCents) } ?? "")
        _paidAt = State(initialValue: payment?.paidAt ?? Date())
        _note = State(initialValue: payment?.note ?? "")
    }
    var body: some View {
        Form {
            Section {
                LabeledContent("工资所属月份", value: monthID)
                TextField("到账金额（元）", text: $amount).keyboardType(.decimalPad)
                    .accessibilityLabel("到账金额")
                DatePicker("实际到账日期", selection: $paidAt, in: ...Date(), displayedComponents: .date)
                TextField("到账备注", text: $note, axis: .vertical).lineLimit(2...5)
            } footer: { Text("可分次登记，跨月到账仍归入 \(monthID) 工资。") }
            .listRowBackground(Color.white)
            if let error = inputError ?? store.errorMessage {
                Section { Text(error).foregroundStyle(PayTheme.cinnabar) }.listRowBackground(Color.white)
            }
        }
        .font(PayTheme.font(17)).foregroundStyle(PayTheme.ink)
        .tint(PayTheme.cinnabar).scrollContentBackground(.hidden).background(Color.white)
        .navigationTitle(payment == nil ? "登记到账" : "修正到账").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).accessibilityIdentifier("payment.save") }
        }
    }
    private func save() {
        inputError = nil
        guard let cents = LedgerNumbers.cents(amount), cents > 0 else {
            inputError = "到账金额须大于零，最多两位小数且不超过一万亿元。"; return
        }
        guard var month = store.month(monthID) else { inputError = "请先保存这个月的应收工资。"; return }
        let updated = SalaryPayment(id: payment?.id ?? UUID(), amountCents: cents, paidAt: paidAt, note: note)
        month.payments.removeAll { $0.id == updated.id }; month.payments.append(updated)
        store.saveMonth(month)
        if store.errorMessage == nil { dismiss() }
    }
}

private enum LedgerEntryMode: String, CaseIterable, Identifiable {
    case expected, remaining
    var id: String { rawValue }
    var title: String { self == .expected ? "全部应收" : "剩余待收" }
}
private struct PaymentEditorRequest: Identifiable {
    let id = UUID()
    let payment: SalaryPayment?
}
private struct LedgerAmountRow: View {
    let title: String
    let cents: Int64
    var emphasized = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(PayTheme.muted)
            Spacer(minLength: 8)
            Text(LedgerNumbers.money(cents))
                .font(PayTheme.font(emphasized ? 24 : 18, weight: emphasized ? .semibold : .regular))
                .foregroundStyle(emphasized ? PayTheme.cinnabar : PayTheme.ink)
                .multilineTextAlignment(.trailing).minimumScaleFactor(0.7)
        }
    }
}
private enum LedgerNumbers {
    static func cents(_ text: String) -> Int64? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: "^[0-9]+(?:\\.[0-9]{1,2})?$", options: .regularExpression) != nil,
              let amount = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), !amount.isNaN,
              amount >= 0, amount <= PayEngine.amount(cents: PayEngine.maximumAmountCents) else { return nil }
        return PayEngine.cents(amount)
    }
    static func input(_ cents: Int64) -> String { NSDecimalNumber(decimal: PayEngine.amount(cents: cents)).stringValue }
    static func money(_ cents: Int64) -> String {
        let format = NumberFormatter(); format.locale = Locale(identifier: "zh_CN")
        format.numberStyle = .currency; format.currencyCode = "CNY"; format.minimumFractionDigits = 2; format.maximumFractionDigits = 2
        return format.string(from: NSDecimalNumber(decimal: PayEngine.amount(cents: cents))) ?? "¥0.00"
    }
    static func date(_ date: Date, timeZone: TimeZone) -> String {
        let format = DateFormatter(); format.locale = Locale(identifier: "zh_CN")
        format.calendar = Calendar(identifier: .gregorian); format.timeZone = timeZone; format.dateFormat = "yyyy年M月d日"
        return format.string(from: date)
    }
}

private struct IncomeCalendarView: View {
    @EnvironmentObject private var store: PayStore
    let monthDate: Date
    let calendar: Calendar
    @State private var selectedDay: Date?
    @State private var now = Date()

    var body: some View {
        let days = PayEngine.incomeCalendar(inMonthOf: monthDate, asOf: now,
                                           entries: store.data.entries, calendar: calendar)
        let regular = days.reduce(Decimal(0)) { $0 + PayEngine.amount(cents: $1.summary.regularCents) }
        let overtime = days.reduce(Decimal(0)) { $0 + PayEngine.amount(cents: $1.summary.overtimeCents) }
        let selected = days.first { calendar.isDate($0.date, inSameDayAs: selectedDay ?? now) } ?? days.first
        // Keep the detail in its own List row so its changing height is
        // included in the scrollable content, even in six-week months.
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("本月累计挣到").font(PayTheme.font(14)).foregroundStyle(PayTheme.muted)
                Text(PayDisplay.money(PayEngine.cents(regular + overtime)))
                    .font(PayTheme.font(36, weight: .semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .accessibilityIdentifier("ledger.earned")
                HStack {
                    Text("正常 " + PayDisplay.money(PayEngine.cents(regular)))
                    Spacer(minLength: 4)
                    Text("加班 " + PayDisplay.money(PayEngine.cents(overtime)))
                }.font(PayTheme.font(12)).foregroundStyle(PayTheme.muted)
            }
            .padding(.bottom, 10)
            .overlay(alignment: .bottom) {
                Rectangle().fill(PayTheme.line.opacity(0.55)).frame(height: 0.5)
            }
            VStack(alignment: .leading, spacing: 18) {
                Text("每天挣多少").font(PayTheme.font(17, weight: .semibold))
                // Eager, bounded rows avoid recursive self-sizing of a lazy grid
                // hosted inside List's UICollectionView on physical iOS devices.
                VStack(spacing: 5) {
                    HStack(spacing: 3) {
                        ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { day in
                            Text(day).font(PayTheme.font(12)).foregroundStyle(PayTheme.muted)
                                .frame(maxWidth: .infinity).padding(.bottom, 6)
                        }
                    }
                    let offset = days.first.map { (calendar.component(.weekday, from: $0.date) + 5) % 7 } ?? 0
                    let rows = (offset + days.count + 6) / 7
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: 3) {
                            ForEach(0..<7, id: \.self) { column in
                                let index = row * 7 + column - offset
                                if days.indices.contains(index) {
                                    dayCell(days[index], selected: selected?.date == days[index].date)
                                        .frame(maxWidth: .infinity)
                                } else {
                                    Color.clear.frame(maxWidth: .infinity).frame(height: 56)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                    }
                }
            }
            HStack {
                Text("点日期看明细")
                Spacer()
                Text("• 含加班　— 未记录")
            }.font(PayTheme.font(11)).foregroundStyle(PayTheme.muted)
            if let selected { detail(selected) }
            if days.contains(where: \.hasConflict) {
                Text("有冲突的时段暂不计入累计，请到加班页核对工作记录。")
                    .font(PayTheme.font(12)).foregroundStyle(PayTheme.cinnabar)
            }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 10, trailing: 12))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.white)
        .onAppear { now = Date() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now = $0 }
        .onChange(of: monthDate) { _, _ in selectedDay = nil }
    }

    private func dayCell(_ day: DailyIncome, selected: Bool) -> some View {
        Button { selectedDay = day.date } label: {
            VStack(spacing: 5) {
                Text(String(calendar.component(.day, from: day.date))).font(PayTheme.font(13))
                Text(day.hasConflict ? "待核对" : day.hasRecords ? compactMoney(day.summary.totalCents) : "—")
                    .font(PayTheme.font(11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
                Circle().fill(day.summary.overtimeSeconds > 0 ? (selected ? Color.white : PayTheme.cinnabar) : Color.clear)
                    .frame(width: 3, height: 3)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .foregroundStyle(selected ? Color.white : day.isFuture ? PayTheme.muted : PayTheme.ink)
            .background(selected ? PayTheme.cinnabar : Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.clear : PayTheme.line.opacity(0.3), lineWidth: day.hasRecords ? 0.5 : 0))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
        .accessibilityLabel("\(calendar.component(.month, from: day.date))月\(calendar.component(.day, from: day.date))日，" +
            (day.hasConflict ? "记录待核对" : day.hasRecords ? "收入\(PayDisplay.money(day.summary.totalCents))" : day.isFuture ? "尚未到来" : "未记录"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("ledger.day.\(calendar.component(.day, from: day.date))")
    }

    private func detail(_ day: DailyIncome) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(calendar.component(.month, from: day.date))月\(calendar.component(.day, from: day.date))日")
                    .font(PayTheme.font(16, weight: .medium))
                Spacer()
                Text(day.hasRecords ? PayDisplay.money(day.summary.totalCents) : day.isFuture ? "尚未到来" : "未记录")
                    .font(PayTheme.font(20, weight: .semibold)).minimumScaleFactor(0.6).lineLimit(1)
            }
            if day.hasRecords {
                LedgerAmountRow(title: "正常收入", cents: day.summary.regularCents)
                LedgerAmountRow(title: "加班收入", cents: day.summary.overtimeCents)
                if day.hasConflict {
                    Text("有记录冲突，以上仅含无冲突收入。")
                        .font(PayTheme.font(12)).foregroundStyle(PayTheme.cinnabar)
                }
            }
        }
        .padding(14)
        .background(Color.white)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(PayTheme.line.opacity(0.55), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ledger.dayDetail")
    }

    private func compactMoney(_ cents: Int64) -> String {
        if cents < 100_000 { return "¥" + NSDecimalNumber(decimal: PayEngine.amount(cents: cents)).stringValue }
        if cents < 1_000_000 { return String(format: "¥%.1fk", Double(cents) / 100_000) }
        return String(format: "¥%.1f万", Double(cents) / 1_000_000)
    }
}
