import SwiftUI
import SwiftData

@main
struct paperpaperApp: App {
    @Environment(\.openWindow) private var openWindow

    init() {
        #if DEBUG
        Store.shared.seedFakeData()
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
            MainWindow()
                .modelContainer(Store.shared.container)
        }
        .windowResizability(.contentSize)
        #else
        WindowGroup {
            MainWindow()
                .modelContainer(Store.shared.container)
        }
        #endif
    }
}

enum WindowID {
    static let main = "main"
}
