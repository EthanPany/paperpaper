import SwiftUI
import os
#if os(macOS)
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "me.ethanpan.paperpaper", category: "menubar")

    private var windowDidBecomeMainObserver: NSObjectProtocol?
    private var windowWillCloseObserver: NSObjectProtocol?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("Menu bar background app must stay alive")
        ProcessInfo.processInfo.disableSuddenTermination()
        terminateDuplicateDebugInstances()

        log.notice("applicationDidFinishLaunching: activationPolicyBefore=\(self.activationPolicyDescription(NSApp.activationPolicy()), privacy: .public) screens=\(NSScreen.screens.count, privacy: .public)")

        installWindowObservers()
        OpenMainWindowBridge.requestOpenMainWindow = { [weak self] in
            self?.openMainWindow()
        }
        updateActivationPolicyForWindowVisibility(reason: "launch")
    }

    private func openMainWindow() {
        // Whoever asked us to open the window expects "the app", which means
        // Photo, never Settings. Reset before activating so the user can't
        // get stranded on Settings after closing the window from there.
        MainWindowState.shared.mode = .photo
        setActivationPolicy(.regular, reason: "open-main-window")
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        for window in NSApp.windows where isMainAppWindow(window) {
            window.makeKeyAndOrderFront(nil)
            updateActivationPolicyForWindowVisibility(reason: "existing-main-window-opened")
            return
        }
        OpenMainWindowBridge.openMainWindow?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.updateActivationPolicyForWindowVisibility(reason: "open-window-bridge")
        }
    }

    private func installWindowObservers() {
        guard windowDidBecomeMainObserver == nil, windowWillCloseObserver == nil else { return }

        windowDidBecomeMainObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let window = notification.object as? NSWindow, self.isMainAppWindow(window) else { return }
            self.updateActivationPolicyForWindowVisibility(reason: "window-did-become-main")
        }

        windowWillCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let window = notification.object as? NSWindow, self.isMainAppWindow(window) else { return }
            self.log.notice("main window will close: title=\(window.title, privacy: .public)")
            DispatchQueue.main.async { [weak self] in
                self?.updateActivationPolicyForWindowVisibility(reason: "main-window-closed")
            }
        }
    }

    private func updateActivationPolicyForWindowVisibility(reason: String) {
        let visibleMainWindows = NSApp.windows.filter { isMainAppWindow($0) && $0.isVisible }
        let desiredPolicy: NSApplication.ActivationPolicy = visibleMainWindows.isEmpty ? .accessory : .regular
        setActivationPolicy(desiredPolicy, reason: reason)
        log.notice("dock policy sync: reason=\(reason, privacy: .public) visibleMainWindows=\(visibleMainWindows.count, privacy: .public) activationPolicy=\(self.activationPolicyDescription(NSApp.activationPolicy()), privacy: .public)")
    }

    private func setActivationPolicy(_ policy: NSApplication.ActivationPolicy, reason: String) {
        let current = NSApp.activationPolicy()
        guard current != policy else { return }
        NSApp.setActivationPolicy(policy)
        log.notice("activation policy changed: reason=\(reason, privacy: .public) from=\(self.activationPolicyDescription(current), privacy: .public) to=\(self.activationPolicyDescription(policy), privacy: .public)")
    }

    private func isMainAppWindow(_ window: NSWindow) -> Bool {
        window.canBecomeMain && !(window is NSPanel)
    }

    private func terminateDuplicateDebugInstances() {
        #if DEBUG
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let duplicates = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).filter { app in
            app.processIdentifier != currentPID && self.isDebugBuildApplication(app)
        }
        guard !duplicates.isEmpty else { return }

        let pids = duplicates.map { String($0.processIdentifier) }.joined(separator: ",")
        log.warning("terminating duplicate debug instances from same bundle: pids=\(pids, privacy: .public)")
        for app in duplicates {
            app.forceTerminate()
        }
        #endif
    }

    private func isDebugBuildApplication(_ app: NSRunningApplication) -> Bool {
        guard let path = app.bundleURL?.standardizedFileURL.path else { return false }
        return path.contains("/DerivedData/") || path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/")
    }

    private func activationPolicyDescription(_ policy: NSApplication.ActivationPolicy) -> String {
        switch policy {
        case .regular:
            return "regular"
        case .accessory:
            return "accessory"
        case .prohibited:
            return "prohibited"
        @unknown default:
            return "unknown-\(policy.rawValue)"
        }
    }
}

enum OpenMainWindowBridge {
    static var openMainWindow: (() -> Void)?
    static var requestOpenMainWindow: (() -> Void)?
}

#endif
