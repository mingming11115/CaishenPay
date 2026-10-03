import SwiftUI
import UIKit

@main
struct CaishenPayApp: App {
    @StateObject private var store = PayStore(demo: ProcessInfo.processInfo.arguments.contains("--demo"))
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = .white
        appearance.shadowColor = .clear
        appearance.titleTextAttributes = [.font: UIFont.systemFont(ofSize: 18, weight: .semibold)]
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UISegmentedControl.appearance().setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 13)], for: .normal)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if store.data.hasCompletedSetup {
                    PayRootView()
                } else {
                    NavigationStack { SettingsView(onboarding: true) }
                }
            }
            .environmentObject(store)
            .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
            .preferredColorScheme(.light)
            .font(PayTheme.font(17))
            .tint(PayTheme.cinnabar)
            .background(KeyboardDismissalInstaller())
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { store.refreshSync() }
            }
        }
    }
}

// Observe taps without consuming button actions or text-field selection gestures.
// Installing on this scene's window also covers the payment editor sheet.
private struct KeyboardDismissalInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> KeyboardDismissalView { KeyboardDismissalView() }
    func updateUIView(_ uiView: KeyboardDismissalView, context: Context) {}
    static func dismantleUIView(_ uiView: KeyboardDismissalView, coordinator: ()) {
        uiView.detach()
    }
}

private final class KeyboardDismissalView: UIView, UIGestureRecognizerDelegate {
    private weak var installedWindow: UIWindow?
    private lazy var outsideTap: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        gesture.cancelsTouchesInView = false
        gesture.delaysTouchesBegan = false
        gesture.delaysTouchesEnded = false
        gesture.delegate = self
        return gesture
    }()

    override func didMoveToWindow() {
        super.didMoveToWindow()
        detach()
        installedWindow = window
        window?.addGestureRecognizer(outsideTap)
    }

    func detach() {
        installedWindow?.removeGestureRecognizer(outsideTap)
        installedWindow = nil
    }

    @objc private func dismissKeyboard() {
        installedWindow?.endEditing(false)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
            // Include descendants: text selection and multiline fields use nested views.
            if current is UITextField || current is UITextView { return false }
            view = current.superview
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}

private struct PayRootView: View {
    @State private var selectedTab = 0
    private let tabs: [(String, String)] = [("今日", "building.columns"), ("加班", "clock"), ("账本", "book"), ("设置", "gearshape")]

    var body: some View {
        // Give scroll views a viewport that ends above the custom tab bar.
        VStack(spacing: 0) {
            Group {
                switch selectedTab {
                case 1: NavigationStack { RecordsView() }
                case 2: NavigationStack { LedgerView() }
                case 3: NavigationStack { SettingsView() }
                default: TodayView(openLedger: { selectedTab = 2 }, openRecords: { selectedTab = 1 })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 0) {
                Rectangle().fill(PayTheme.line.opacity(0.65)).frame(height: 0.5)
                HStack(spacing: 0) {
                    ForEach(tabs.indices, id: \.self) { index in
                        Button { selectedTab = index } label: {
                            VStack(spacing: 5) {
                                Image(systemName: tabs[index].1).font(.system(size: 22, weight: .light))
                                Text(tabs[index].0).font(PayTheme.font(14))
                                Capsule().fill(selectedTab == index ? PayTheme.cinnabar : .clear).frame(width: 28, height: 2)
                            }
                            .foregroundStyle(selectedTab == index ? PayTheme.cinnabar : PayTheme.ink)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 11)
                            .padding(.bottom, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("tab.\(index)")
                        .accessibilityAddTraits(selectedTab == index ? .isSelected : [])
                    }
                }
            }
            .background(Color.white)
        }
        .background(Color.white)
    }
}
