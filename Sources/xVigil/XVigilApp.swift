import AppKit
import SwiftUI

@main
struct XVigilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = VigilModel()
    @State private var monitor: DetectionMonitor
    @State private var dashboard: DashboardModel

    init() {
        let monitor = DetectionMonitor()
        _monitor = State(initialValue: monitor)
        _dashboard = State(initialValue: DashboardModel(monitor: monitor))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model, dashboard: dashboard, monitor: monitor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)

        Window("xVigil", id: "dashboard") {
            DashboardView(model: dashboard, monitor: monitor)
        }
        .defaultSize(width: 960, height: 600)
        // Menu bar app: the dashboard opens on demand, not at launch.
        .defaultLaunchBehavior(.suppressed)
    }
}

/// The menu bar icon is the app's loudest surface: it flips to a red warning
/// shield whenever any finding is active, so a detection is visible without
/// opening anything.
private struct MenuBarLabel: View {
    let monitor: DetectionMonitor

    var body: some View {
        Image(systemName: monitor.count > 0
            ? "exclamationmark.shield.fill"
            : "shield.lefthalf.filled")
            .foregroundStyle(monitor.count > 0 ? .red : .primary)
            .onAppear { monitor.start() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon. Needed because `swift run` launches
        // us without a bundle, so there is no Info.plist LSUIElement key.
        NSApp.setActivationPolicy(.accessory)
    }
}
