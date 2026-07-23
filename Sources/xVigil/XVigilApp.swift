import AppKit
import SwiftUI

@main
struct XVigilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = VigilModel()
    @State private var monitor: DetectionMonitor
    @State private var scanner: ScanController
    @State private var updates = UpdateChecker()
    @State private var dashboard: DashboardModel

    init() {
        let monitor = DetectionMonitor()
        let scanner = ScanController(monitor: monitor)
        _monitor = State(initialValue: monitor)
        _scanner = State(initialValue: scanner)
        _dashboard = State(initialValue: DashboardModel(monitor: monitor, scanner: scanner))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model, dashboard: dashboard, monitor: monitor, updates: updates)
        } label: {
            MenuBarLabel(monitor: monitor, scanner: scanner, updates: updates)
        }
        .menuBarExtraStyle(.window)

        Window("xVigil", id: "dashboard") {
            DashboardView(model: dashboard, monitor: monitor, updates: updates)
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
    let scanner: ScanController
    let updates: UpdateChecker

    var body: some View {
        Image(systemName: monitor.count > 0
            ? "exclamationmark.shield.fill"
            : "shield.lefthalf.filled")
            .foregroundStyle(monitor.count > 0 ? .red : .primary)
            .onAppear {
                monitor.start()
                scanner.start()
                updates.start()
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Build-time hook: make-app.sh runs the binary with this env var to
        // dump the programmatic icon as a PNG for the bundle's .icns.
        if let iconPath = ProcessInfo.processInfo.environment["XVIGIL_DUMP_ICON"] {
            AppIcon.writePNG(to: iconPath)
            exit(0)
        }
        // Menu-bar app: start without a Dock icon; DockPresence adds one
        // while the dashboard window is open. The explicit policy matters
        // because `swift run` launches us without a bundle Info.plist.
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = AppIcon.image(size: 512)
    }
}

/// The Dock icon appears while the dashboard is open (like System Settings
/// panes from menu bar apps) and disappears when it closes, keeping the app
/// menu-bar-native the rest of the time.
@MainActor
enum DockPresence {
    static func dashboardOpened() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    static func dashboardClosed() {
        NSApp.setActivationPolicy(.accessory)
    }
}
