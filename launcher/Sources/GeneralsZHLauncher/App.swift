import SwiftUI
import AppKit

@main
struct GeneralsZHLauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = LauncherModel()

    var body: some Scene {
        WindowGroup("Generals Zero Hour — Launcher") {
            ContentView()
                .environmentObject(model)
                .frame(width: 560, height: 560)
        }
    }
}

/// Makes the single window a fixed-size, centered, non-resizable panel and
/// brings the app to the front on launch (macOS 12 compatible — avoids the
/// macOS 13-only `windowResizability` scene modifier).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first {
            window.styleMask.remove(.resizable)
            window.center()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
