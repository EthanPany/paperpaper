import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

@main
struct paperpaperApp: App {
    @Environment(\.openWindow) private var openWindow
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    init() {
        #if DEBUG
        Store.shared.seedFakeData()
        #endif
        #if os(macOS)
        if UserDefaults.standard.bool(forKey: "app.hideDockIcon") {
            NSApp.setActivationPolicy(.accessory)
        }
        #endif
        RotationEngine.shared.startIfEnabled()
    }

    var body: some Scene {
        #if os(macOS)
        MenuBarExtra {
            MenuBarContent {
                openWindow(id: WindowID.main)
            }
        } label: {
            Image(systemName: "photo.on.rectangle.angled")
        }
        .menuBarExtraStyle(.window)

        Window("paperpaper", id: WindowID.main) {
            NowView()
                .modelContainer(Store.shared.container)
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsScene()
                .modelContainer(Store.shared.container)
        }
        #else
        WindowGroup {
            NowView()
                .modelContainer(Store.shared.container)
        }
        #endif
    }
}

enum WindowID {
    static let main = "main"
}
