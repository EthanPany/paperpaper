import SwiftUI

struct MainWindow: View {
    @State private var selection: Tab = .now

    var body: some View {
        TabView(selection: $selection) {
            NowView()
                .tabItem { Label("Now", systemImage: "photo") }
                .tag(Tab.now)

            LibraryView()
                .tabItem { Label("Library", systemImage: "square.grid.2x2") }
                .tag(Tab.library)

            DiscoverView()
                .tabItem { Label("Discover", systemImage: "sparkles") }
                .tag(Tab.discover)

            RotationView()
                .tabItem { Label("Rotation", systemImage: "clock.arrow.2.circlepath") }
                .tag(Tab.rotation)

            OverlayView()
                .tabItem { Label("Overlay", systemImage: "textformat") }
                .tag(Tab.overlay)

            CacheView()
                .tabItem { Label("Cache", systemImage: "externaldrive") }
                .tag(Tab.cache)

            SyncView()
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath.icloud") }
                .tag(Tab.sync)

            ConnectionsView()
                .tabItem { Label("Connections", systemImage: "link") }
                .tag(Tab.connections)

            AdvancedView()
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
                .tag(Tab.advanced)
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

enum Tab: Hashable {
    case now, library, discover, rotation, overlay, cache, sync, connections, advanced
}

#Preview {
    MainWindow()
}
