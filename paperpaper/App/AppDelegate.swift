import SwiftUI
#if os(macOS)
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launch into the background. Don't force the main window forward.
        if UserDefaults.standard.bool(forKey: "app.hideDockIcon") {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
#endif
