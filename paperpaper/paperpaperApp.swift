import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

@main
struct paperpaperApp: App {
    @Environment(\.openWindow) private var openWindow

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
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 960, height: 640)
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
