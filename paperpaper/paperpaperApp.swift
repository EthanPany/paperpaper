import SwiftUI
import SwiftData
import os
#if os(macOS)
import AppKit
#endif

@main
struct paperpaperApp: App {
    private static let log = Logger(subsystem: "me.ethanpan.paperpaper", category: "app-lifecycle")

    @Environment(\.openWindow) private var openWindow
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    init() {
        Self.log.notice("paperpaperApp.init started")
        // Register baseline defaults BEFORE anything else runs. `register(defaults:)`
        // only fills slots the user hasn't explicitly set, so this is safe to
        // run on every launch — it gives a fresh install sensible values
        // (local Ollama + qwen3-vl:2b-instruct vision model) without
        // overwriting whatever the user has chosen.
        UserDefaults.standard.register(defaults: [
            "ollama.url": "http://localhost:11434",
            "ollama.model": "qwen3-vl:2b-instruct",
            "ollama.temperature": 0.2,
            "ollama.timeoutSeconds": 30.0,
        ])
        #if DEBUG
        Self.log.notice("paperpaperApp.init seeding debug data")
        Store.shared.seedFakeData()
        #endif
        // One-time cleanup: an earlier build wrote bad "external-…" payloads
        // when the desktop wallpaper came from a sandbox-protected source we
        // couldn't read (e.g. the Unsplash Wallpapers app's container). The
        // payload landed in the App Group with empty imageFileName and stuck
        // around forever. Clear those out at startup so the next rotation
        // starts from a clean slate instead of rendering the bad payload.
        if let existing = WidgetPayload.read(),
           existing.unsplashID.hasPrefix("external-"),
           existing.imageFileName.isEmpty {
            Self.log.notice("paperpaperApp.init clearing stale external widget payload")
            if let defaults = UserDefaults(suiteName: WidgetPayload.appGroup) {
                defaults.removeObject(forKey: WidgetPayload.defaultsKey)
            }
            try? FileManager.default.removeItem(at: WidgetPayload.payloadFileURL())
        }

        // Keep the widget in sync with the actual macOS desktop image —
        // catches our own rotations, manual System Settings changes, and
        // late-arriving enrichment text.
        Self.log.notice("paperpaperApp.init starting wallpaper watcher")
        WallpaperWatcher.shared.start()
        // Always-on space observer: every active-space change triggers a
        // lightweight reapply of the most-recent wallpaper on the now-active
        // Space (gated to `spaceMode == .unified`). Owned at app scope so it
        // works regardless of whether rotation is running or paused — the
        // most reported failure was "switched to a new Space and the
        // wallpaper didn't follow". Independent of RotationEngine so a
        // paused schedule still keeps Spaces in sync.
        Self.log.notice("paperpaperApp.init starting space observer")
        SpaceObserver.shared.onChange = {
            Task { @MainActor in
                await WallpaperApplier.shared.reapplyOnCurrentSpace()
            }
        }
        SpaceObserver.shared.start()
        Self.log.notice("paperpaperApp.init starting rotation engine")
        RotationEngine.shared.startIfEnabled()
        Self.log.notice("paperpaperApp.init starting iCloud sync coordinator")
        iCloudSyncCoordinator.shared.start()
        Self.log.notice("paperpaperApp.init completed")
    }

    var body: some Scene {
        #if os(macOS)
        Window("paperpaper", id: WindowID.main) {
            MainWindowRouter()
                .modelContainer(Store.shared.container)
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .onAppear {
                    OpenMainWindowBridge.openMainWindow = {
                        openWindow(id: WindowID.main)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // SwiftUI menu-bar item. Replaces the AppKit NSStatusItem/NSPopover
        // setup so MenuBarContent inherits the scene environment — most
        // importantly `\.openWindow`, which can open the SwiftUI Window
        // scene whether or not it's been shown before. The previous bridge-
        // via-`.onAppear` pattern was nil on first launch (LSUIElement=YES,
        // window never shown) and silently dropped the menu-bar "Open
        // paperpaper…" click.
        MenuBarExtra("paperpaper", systemImage: "photo.stack.fill") {
            MenuBarContent()
                .modelContainer(Store.shared.container)
        }
        .menuBarExtraStyle(.window)
        #else
        WindowGroup {
            MainWindowRouter()
                .modelContainer(Store.shared.container)
        }
        #endif
    }
}

enum WindowID {
    static let main = "main"
}
