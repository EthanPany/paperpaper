import SwiftUI
import os
#if os(macOS)
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "me.ethanpan.paperpaper", category: "menubar")

    private var windowDidBecomeMainObserver: NSObjectProtocol?
    private var windowWillCloseObserver: NSObjectProtocol?

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

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
        installStatusItem()
        updateActivationPolicyForWindowVisibility(reason: "launch")
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: 28)
        item.behavior = [.removalAllowed]
        item.autosaveName = "me.ethanpan.paperpaper.menubar"
        item.isVisible = true
        if let button = item.button {
            let image = NSImage(systemSymbolName: "photo.stack.fill", accessibilityDescription: "paperpaper")
                ?? NSImage(systemSymbolName: "photo", accessibilityDescription: "paperpaper")
            image?.size = NSSize(width: 18, height: 18)
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(statusItemClicked(_:))
        }
        statusItem = item
        log.notice("status item created: visible=\(item.isVisible) length=\(item.length) hasImage=\(item.button?.image != nil)")

        let popover = NSPopover()
        popover.behavior = .transient
        // Tall enough for: wallpaper preview (150) + status block (~80) +
        // five action buttons (~26 each) + open / quit (~52). NSPopover
        // doesn't auto-resize; SwiftUI's intrinsic content goes through this
        // value, so undersize → content gets clipped.
        popover.contentSize = NSSize(width: 300, height: 540)
        popover.contentViewController = NSHostingController(rootView: MenuBarContent(openMainWindow: { [weak self] in
            self?.popover?.performClose(nil)
            self?.openMainWindow()
        }))
        self.popover = popover

        log.notice("installed AppKit NSStatusItem with autosaveName=me.ethanpan.paperpaper.menubar")
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func openMainWindow() {
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
