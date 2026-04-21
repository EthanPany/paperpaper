import SwiftUI

@main
struct paperpaperApp: App {
    @Environment(\.openWindow) private var openWindow

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
        }
        .windowResizability(.contentSize)
        #else
        WindowGroup {
            MainWindow()
        }
        #endif
    }
}

enum WindowID {
    static let main = "main"
}
