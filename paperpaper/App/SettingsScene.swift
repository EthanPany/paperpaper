import SwiftUI

struct SettingsScene: View {
    var body: some View {
        TabView {
            DiscoverView()
                .tabItem { Label("Discover", systemImage: "sparkles") }
            LibraryView()
                .tabItem { Label("Library", systemImage: "square.grid.2x2") }
            RotationView()
                .tabItem { Label("Rotation", systemImage: "clock.arrow.2.circlepath") }
            OverlayView()
                .tabItem { Label("Overlay", systemImage: "textformat") }
            CacheView()
                .tabItem { Label("Cache", systemImage: "externaldrive") }
            SyncView()
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath.icloud") }
            ConnectionsView()
                .tabItem { Label("Connections", systemImage: "link") }
            AdvancedView()
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}
