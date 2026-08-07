import AppKit
import SwiftUI

@main
struct XVigilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = VigilModel()
    @State private var monitor: DetectionMonitor
    @State private var scanner: ScanController
    @State private var watchlist: WatchlistController
    @State private var updates = UpdateChecker()
    @State private var dashboard: DashboardModel

    init() {
        let monitor = DetectionMonitor()
        let scanner = ScanController(monitor: monitor)
        let watchlist = WatchlistController(monitor: monitor)
        _monitor = State(initialValue: monitor)
        _scanner = State(initialValue: scanner)
        _watchlist = State(initialValue: watchlist)
        _dashboard = State(initialValue: DashboardModel(
            monitor: monitor, scanner: scanner, watchlist: watchlist))
    }

    /// Always suppressed in release. Debug builds honor XVIGIL_UITEST, which
    /// opens the dashboard at launch so the real view layer can be exercised
    /// headlessly — the only way to catch view-level bugs like a `.task` that
    /// never re-runs, which no model-level test can see.
    private static var dashboardLaunchBehavior: SceneLaunchBehavior {
        #if DEBUG
            if ProcessInfo.processInfo.environment["XVIGIL_UITEST"] != nil {
                return .presented
            }
        #endif
        return .suppressed
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model, dashboard: dashboard, monitor: monitor, updates: updates)
        } label: {
            MenuBarLabel(
                monitor: monitor, scanner: scanner, watchlist: watchlist, updates: updates)
        }
        .menuBarExtraStyle(.window)

        Window("xVigil", id: "dashboard") {
            DashboardView(model: dashboard, monitor: monitor, updates: updates)
        }
        .defaultSize(width: 960, height: 600)
        // Menu bar app: the dashboard opens on demand, not at launch.
        .defaultLaunchBehavior(Self.dashboardLaunchBehavior)
        .commands {
            // Show the programmatic icon (the same drawing as the Dock icon)
            // in the About panel. Running via `swift run` there is no bundle
            // .icns, so without this the panel falls back to a generic icon.
            CommandGroup(replacing: .appInfo) {
                Button("About xVigil") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationIcon: AppIcon.image(size: 512),
                        .applicationName: "xVigil",
                    ])
                }
            }
            // Help goes to the project page instead of the (nonexistent)
            // Apple Help book.
            CommandGroup(replacing: .help) {
                Button("xVigil Help") {
                    NSWorkspace.shared.open(
                        URL(string: "https://github.com/ServerWrestler/xVigil")!)
                }
            }
        }
    }
}

/// The menu bar icon is the app's loudest surface: it flips to a red warning
/// shield whenever any finding is active, so a detection is visible without
/// opening anything.
private struct MenuBarLabel: View {
    let monitor: DetectionMonitor
    let scanner: ScanController
    let watchlist: WatchlistController
    let updates: UpdateChecker

    var body: some View {
        Image(systemName: monitor.count > 0
            ? "exclamationmark.shield.fill"
            : "shield.lefthalf.filled")
            .foregroundStyle(monitor.count > 0 ? .red : .primary)
            .onAppear {
                monitor.start()
                scanner.start()
                watchlist.start()
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
