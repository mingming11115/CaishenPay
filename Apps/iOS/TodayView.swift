import SwiftUI
import WorkPayCore

struct TodayView: View {
    @EnvironmentObject private var store: PayStore
    let openLedger: () -> Void
    let openRecords: () -> Void
    @State private var showOvertime = false

    private var rule: PaySettings? { store.activeEntry?.settings ?? store.currentSettings }
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: rule?.timeZoneID ?? "Asia/Shanghai")!
        return value
    }

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let summary = store.summary(on: timeline.date, now: timeline.date)
                ScrollView {
                    VStack(spacing: 0) {
                        JiangnanArtwork(height: geometry.size.width * 414 / 505)
                        VStack(spacing: 8) {
                            income(summary)
                            shift(summary, now: timeline.date)
                            controls
                            ledger(now: timeline.date)
                            notices
                        }
                        .padding(.horizontal, 25)
                        .padding(.top, 3)
                        .padding(.bottom, 22)
                    }
                }
                .scrollIndicators(.hidden)
                .background(Color.white)
            }
        }
        .foregroundStyle(PayTheme.ink)
        .confirmationDialog(store.activeEntry == nil ? "开始哪种加班？" : "结束当前计时并开始加班", isPresented: $showOvertime, titleVisibility: .visible) {
            ForEach([WorkKind.weekday, .weekend, .holiday]) { kind in
                Button(overtimeTitle(kind)) { startOvertime(kind) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请按实际班表选择；周末调休也可以使用工作日倍率。")
        }
        .alert("未能完成", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("知道了") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private func income(_ summary: DaySummary) -> some View {
        VStack(spacing: 12) {
            Text(PayDisplay.money(summary.totalCents))
                .font(PayTheme.font(46, weight: .semibold))
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .monospacedDigit()
                .accessibilityLabel("今日估算收入 \(PayDisplay.money(summary.totalCents))")
                .accessibilityIdentifier("today.income")
            HStack(spacing: 0) {
                incomeColumn("正常收入", cents: summary.regularCents)
                Rectangle().fill(PayTheme.line).frame(width: 0.5, height: 44)
                incomeColumn("加班收入", cents: summary.overtimeCents)
            }
        }
    }

    private func incomeColumn(_ title: String, cents: Int64) -> some View {
        VStack(spacing: 6) {
            Text(title).font(PayTheme.font(15)).foregroundStyle(PayTheme.muted)
            Text(PayDisplay.money(cents)).font(PayTheme.font(19, weight: .medium))
                .lineLimit(1).minimumScaleFactor(0.6).monospacedDigit()
        }.frame(maxWidth: .infinity)
    }

    private func shift(_ summary: DaySummary, now: Date) -> some View {
        VStack(spacing: 7) {
            Text(store.attendanceStatusText)
                .font(PayTheme.font(17)).foregroundStyle(PayTheme.cinnabar)
                .accessibilityIdentifier("today.attendance")
            if let days = try? MainlandWorkCalendar.workdays(inMonthOf: now), let rule {
                Text("本月工作日 \(days)天 · 每日 \(PayDisplay.money(PayEngine.cents(rule.monthlyBase / Decimal(days))))")
                    .font(PayTheme.font(13)).foregroundStyle(PayTheme.muted)
            } else {
                Text("本年度调休日历未收录，请更新日历数据")
                    .font(PayTheme.font(13)).foregroundStyle(PayTheme.cinnabar)
            }
            if let active = store.activeEntry {
                Text(active.kind == .regular ? "旧版上班计时待结束，请到工作记录处理" : "\(active.kind.title) · 本段 \(PayDisplay.duration(now.timeIntervalSince(active.start)))")
                    .font(PayTheme.font(13)).foregroundStyle(PayTheme.cinnabar)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button {
                switch store.attendanceStatusToday {
                case .none: store.markToday()
                case .legacy, .conflict: openRecords()
                case .recorded: break
                }
            } label: {
                Label("今日上班", systemImage: store.attendanceStatusToday == .recorded ? "checkmark.circle.fill" : "calendar.badge.plus")
            }
            .buttonStyle(CinnabarButtonStyle(filled: false))
            .disabled(store.attendanceStatusToday == .recorded)
            .accessibilityIdentifier("today.regular")
            Button {
                if let active = store.activeEntry, active.kind != .regular { store.stop() }
                else { showOvertime = true }
            } label: {
                Label(store.activeEntry != nil && store.activeEntry?.kind != .regular ? "结束加班" : "开始加班", systemImage: "clock")
            }
            .buttonStyle(CinnabarButtonStyle())
            .accessibilityIdentifier("today.overtime")
        }
    }

    private func ledger(now: Date) -> some View {
        let components = calendar.dateComponents([.year, .month], from: now)
        let monthID = String(format: "%04d-%02d", components.year!, components.month!)
        let month = store.month(monthID)
        return Button(action: openLedger) {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Text("工资账本").font(PayTheme.font(22, weight: .medium))
                    Rectangle().fill(PayTheme.line).frame(height: 0.5)
                    Text("\(components.month!)月 ›").font(PayTheme.font(13)).fixedSize()
                }
                if let month {
                    HStack(alignment: .top, spacing: 0) {
                        ledgerColumn("已到账", cents: month.receivedCents)
                        ledgerColumn("未到账", cents: month.outstandingCents)
                    }
                } else {
                    HStack {
                        Text("本月尚未记账").font(PayTheme.font(16))
                        Spacer()
                        Text("录入到账与待收 ›").font(PayTheme.font(13)).foregroundStyle(PayTheme.cinnabar)
                    }
                }
            }
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("today.ledger")
    }

    private func ledgerColumn(_ title: String, cents: Int64) -> some View {
        HStack(spacing: 12) {
            Rectangle().fill(PayTheme.line).frame(width: 0.5)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(PayTheme.font(14)).foregroundStyle(PayTheme.muted)
                Text(PayDisplay.money(cents)).font(PayTheme.font(22, weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            Spacer(minLength: 5)
        }.frame(maxWidth: .infinity)
    }

    @ViewBuilder private var notices: some View {
        if !store.conflictIDs.isEmpty || store.data.entries.contains(where: { $0.deletedAt == nil && $0.needsTypeReview }) {
            Button(action: openRecords) {
                Label(store.conflictIDs.isEmpty ? "跨日加班待确认类型 ›" : "有重叠记录，请核对后计薪 ›", systemImage: "exclamationmark.circle")
                    .font(PayTheme.font(13)).foregroundStyle(PayTheme.cinnabar)
            }.buttonStyle(.plain)
        }
        if store.currentSettings == nil {
            Text("工资规则尚未生效，请在设置中检查日期。")
                .font(PayTheme.font(13)).foregroundStyle(PayTheme.cinnabar)
        }
        if store.syncStatus != "请在手表安装财神记薪" {
            Text(store.syncStatus)
                .font(PayTheme.font(11)).foregroundStyle(PayTheme.muted)
                .multilineTextAlignment(.center)
        }
    }

    private func overtimeTitle(_ kind: WorkKind) -> String {
        let multiplier = NSDecimalNumber(decimal: store.currentSettings?.multiplier(for: kind) ?? 1).stringValue
        return "\(kind.title) · \(multiplier)倍"
    }
    private func startOvertime(_ kind: WorkKind) {
        let now = Date()
        if store.activeEntry != nil {
            store.stop(at: now)
            guard store.errorMessage == nil else { return }
        }
        store.begin(kind, at: now)
    }
    private func clock(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }

}
