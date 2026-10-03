import SwiftUI
import WorkPayCore

@main
struct CaishenWatchApp: App {
    @StateObject private var store = PayStore(demo: ProcessInfo.processInfo.arguments.contains("--demo"))

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                WatchTodayView()
            }
            .environmentObject(store)
            .preferredColorScheme(.light)
            .font(PayTheme.font(14))
        }
    }
}

private struct WatchTodayView: View {
    @EnvironmentObject private var store: PayStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingKindPicker = false
    @State private var selectedKind: WorkKind?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            ScrollView {
                VStack(spacing: 5) {
                    JiangnanArtwork(height: 28)
                        .accessibilityHidden(true)
                    if store.data.hasCompletedSetup, store.currentSettings != nil {
                        overview(at: timeline.date)
                        timerControls
                        recordDetails(at: timeline.date)
                    } else {
                        VStack(spacing: 8) {
                            Text("先在 iPhone 设置")
                                .font(PayTheme.font(17, weight: .semibold))
                            Text("确认月薪与班次后\n手表即可查看收入、记录加班")
                                .font(PayTheme.font(13))
                                .foregroundStyle(PayTheme.muted)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.vertical, 8)
                    }
                    syncDetails
                        .padding(.top, 9)
                }
                .padding(.horizontal, 9)
                .padding(.bottom, 8)
            }
            .background(Color.white)
            .foregroundStyle(PayTheme.ink)
        }
        .containerBackground(Color.white, for: .navigation)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.refreshSync() }
        }
        .sheet(isPresented: $showingKindPicker, onDismiss: {
            // Start after the sheet has closed, so a validation error can present reliably.
            if let kind = selectedKind {
                selectedKind = nil
                store.begin(kind)
            }
        }) {
            overtimeChoices
        }
        .alert("未能完成", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("知道了") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private func overview(at now: Date) -> some View {
        let summary = store.summary(on: now, now: now)
        return VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text("今日")
                    .font(PayTheme.font(14, weight: .medium))
                Spacer()
                Text("收入估算")
                    .font(PayTheme.font(10))
                    .foregroundStyle(PayTheme.muted)
            }
            Text(PayDisplay.money(summary.totalCents))
                .font(PayTheme.font(35, weight: .semibold))
                .minimumScaleFactor(0.38)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("今日估算收入 \(PayDisplay.money(summary.totalCents))")
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(store.attendanceStatusText)
                    .font(PayTheme.font(12))
                    .minimumScaleFactor(0.75)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if store.pendingCount > 0 {
                    Text("待同步")
                        .font(PayTheme.font(9))
                        .foregroundStyle(PayTheme.cinnabar)
                }
            }
            if summary.overtimeSeconds > 0 {
                Text("加班 \(PayDisplay.duration(summary.overtimeSeconds))")
                    .font(PayTheme.font(11)).foregroundStyle(PayTheme.muted)
            }
        }
    }

    @ViewBuilder
    private var timerControls: some View {
        if let active = store.activeEntry, active.kind != .regular {
            Button { store.stop() } label: {
                Text("结束加班")
            }
            .buttonStyle(WatchActionStyle())
        } else {
            Button { showingKindPicker = true } label: {
                Text("开始加班")
            }
            .buttonStyle(WatchActionStyle())
            .disabled(store.activeEntry != nil)
            .opacity(store.activeEntry != nil ? 0.5 : 1)
        }
    }

    @ViewBuilder
    private func recordDetails(at now: Date) -> some View {
        if let active = store.activeEntry {
            if active.kind == .regular {
                Text("旧版上班计时 · 请在手机结束")
                    .font(PayTheme.font(11))
                    .foregroundStyle(PayTheme.muted)
                    .multilineTextAlignment(.center)
            } else {
                Text("\(active.kind.title) · \(elapsed(max(0, now.timeIntervalSince(active.start))))")
                    .font(PayTheme.font(11))
                    .foregroundStyle(PayTheme.muted)
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
            }
        }
        if !store.conflictIDs.isEmpty {
            Text("记录重叠，暂不计入收入\n请在手机修正")
                .font(PayTheme.font(11))
                .foregroundStyle(PayTheme.cinnabar)
                .multilineTextAlignment(.center)
        }
    }

    private var overtimeChoices: some View {
        ScrollView {
            VStack(spacing: 9) {
                Text("选择加班类型")
                    .font(PayTheme.font(15, weight: .semibold))
                    .padding(.bottom, 3)
                ForEach([WorkKind.weekday, .weekend, .holiday]) { kind in
                    Button {
                        selectedKind = kind
                        showingKindPicker = false
                    } label: {
                        Text(kind.title)
                            .font(PayTheme.font(14))
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .foregroundStyle(PayTheme.ink)
                            .background(Color.white)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(PayTheme.line, lineWidth: 0.8))
                    }
                    .buttonStyle(.plain)
                }
                Button("返回") { showingKindPicker = false }
                    .font(PayTheme.font(12))
                    .buttonStyle(.plain)
                    .foregroundStyle(PayTheme.cinnabar)
                    .padding(.vertical, 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(Color.white.ignoresSafeArea())
        .foregroundStyle(PayTheme.ink)
        .preferredColorScheme(.light)
    }

    private var syncDetails: some View {
        VStack(spacing: 5) {
            Divider().overlay(PayTheme.muted.opacity(0.15))
            Text(store.syncStatus)
                .font(PayTheme.font(10))
                .foregroundStyle(PayTheme.muted)
                .multilineTextAlignment(.center)
            if store.pendingCount > 0 {
                Text("\(store.pendingCount) 条记录已保存在手表")
                    .font(PayTheme.font(10))
                    .foregroundStyle(PayTheme.cinnabar)
            }
            if let lastSync = store.lastSync {
                Text("上次同步 \(lastSync.formatted(.dateTime.month().day().hour().minute()))")
                    .font(PayTheme.font(10))
                    .foregroundStyle(PayTheme.muted)
                    .multilineTextAlignment(.center)
            }
            Button { store.refreshSync() } label: {
                Text("同步手机").font(PayTheme.font(12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(PayTheme.cinnabar)
            .padding(.vertical, 4)
        }
    }

    private func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }
}

private struct WatchActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PayTheme.font(15, weight: .medium))
            .frame(maxWidth: .infinity, minHeight: 40)
            .foregroundStyle(.white)
            .background(PayTheme.cinnabar)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(PayTheme.cinnabar, lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: 2).inset(by: 3).stroke(Color.white.opacity(0.8), lineWidth: 0.6))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
