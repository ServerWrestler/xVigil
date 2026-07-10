import AppKit
import SwiftUI

@main
struct XVigilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = VigilModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            Image(systemName: "shield.lefthalf.filled")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon. Needed because `swift run` launches
        // us without a bundle, so there is no Info.plist LSUIElement key.
        NSApp.setActivationPolicy(.accessory)
    }
}
