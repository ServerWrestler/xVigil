import AppKit
import SwiftUI

@main
struct XVigilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = VigilModel()
    @State private var dashboard = DashboardModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model, dashboard: dashboard)
        } label: {
            Image(systemName: "shield.lefthalf.filled")
        }
        .menuBarExtraStyle(.window)

        Window("xVigil", id: "dashboard") {
            DashboardView(model: dashboard)
        }
        .defaultSize(width: 960, height: 600)
        // Menu bar app: the dashboard opens on demand, not at launch.
        .defaultLaunchBehavior(.suppressed)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon. Needed because `swift run` launches
        // us without a bundle, so there is no Info.plist LSUIElement key.
        NSApp.setActivationPolicy(.accessory)
    }
}
