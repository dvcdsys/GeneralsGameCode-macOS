import SwiftUI
import AppKit

@main
struct GeneralsZHLauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = LauncherModel()

    var body: some Scene {
        WindowGroup("Generals Zero Hour — Launcher") {
            RootView()
                .environmentObject(model)
        }
    }
}

/// Centers the window and brings the app to the front on launch. The window is
/// resizable (min size comes from RootView's frame). macOS 12 compatible —
/// avoids the macOS 13-only `windowResizability` scene modifier.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first {
            window.center()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
