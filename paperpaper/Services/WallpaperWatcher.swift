import Foundation
import os
#if os(macOS)
import AppKit
#endif

/// Keeps the widget payload in sync with whatever the macOS desktop is
/// actually showing right now. macOS doesn't expose a "wallpaper changed"
/// notification, so we triangulate: app activation + active-space change
/// + a slow timer. Every signal calls `syncWidgetFromCurrent`, which is
/// idempotent and a no-op when nothing has changed.
@MainActor
final class WallpaperWatcher {
    static let shared = WallpaperWatcher()

    private let log = Logger(subsystem: "ep.paperpaper", category: "wallpaper-watcher")

    #if os(macOS)
    private var spaceToken: NSObjectProtocol?
    private var activeToken: NSObjectProtocol?
    #endif
    private var timer: Timer?

    func start() {
        #if os(macOS)
        guard spaceToken == nil else { return }

        // Active-space change: payload is usually unchanged, so let
        // commitPayload's idempotence skip the reload.
        spaceToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                WallpaperApplier.shared.syncWidgetFromCurrent()
            }
        }

        // App-becomes-active = user just came back to paperpaper. Force a
        // widget reload — chronod is allowed to drop our scheduled timeline
        // updates (FB11522170 on macOS 26), and "I just opened the app and
        // the widget shows yesterday's photo" is the most-reported failure
        // mode. The cost is one extra reload per focus event, which is fine.
        activeToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                WallpaperApplier.shared.syncWidgetFromCurrent(forceReload: true)
            }
        }

        // 30s slow tick. The actual macOS API for wallpaper changes is
        // private, so we poll. syncWidgetFromCurrent short-circuits when
        // nothing changed, so this is cheap.
        let timer = Timer(timeInterval: 30, repeats: true) { _ in
            Task { @MainActor in
                WallpaperApplier.shared.syncWidgetFromCurrent()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        log.info("WallpaperWatcher started")
        // Initial sync at startup. forceReload=true so the widget renders
        // the current photo even when the app group already had the right
        // payload bytes — chronod sometimes serves stale snapshots after a
        // device reboot or extension respawn, and a fresh launch is the
        // cheapest moment to invalidate them.
        Task { @MainActor in
            WallpaperApplier.shared.syncWidgetFromCurrent(forceReload: true)
        }
        #endif
    }

    func stop() {
        #if os(macOS)
        if let t = spaceToken { NSWorkspace.shared.notificationCenter.removeObserver(t) }
        if let t = activeToken { NotificationCenter.default.removeObserver(t) }
        spaceToken = nil
        activeToken = nil
        #endif
        timer?.invalidate()
        timer = nil
    }
}
