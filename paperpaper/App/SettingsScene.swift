import SwiftUI

/// Settings content rendered inside the main window (not a separate Settings scene).
struct SettingsPane: View {
    enum Section: String, Hashable, CaseIterable {
        case discover, library, schedule, connections, sync, data

        var label: String {
            switch self {
            case .discover: return "Discover"
            case .library: return "Library"
            case .schedule: return "Schedule"
            case .connections: return "Connections"
            case .sync: return "Sync"
            case .data: return "Data"
            }
        }

        var icon: String {
            switch self {
            case .discover: return "sparkles"
            case .library: return "square.grid.2x2"
            case .schedule: return "clock.arrow.2.circlepath"
            case .connections: return "link"
            case .sync: return "icloud"
            case .data: return "externaldrive"
            }
        }
    }

    @State private var section: Section = .discover

    var body: some View {
        TabView(selection: $section) {
            DiscoverView()
                .tabItem { Label(Section.discover.label, systemImage: Section.discover.icon) }
                .tag(Section.discover)
            LibraryView()
                .tabItem { Label(Section.library.label, systemImage: Section.library.icon) }
                .tag(Section.library)
            RotationView()
                .tabItem { Label(Section.schedule.label, systemImage: Section.schedule.icon) }
                .tag(Section.schedule)
            ConnectionsView()
                .tabItem { Label(Section.connections.label, systemImage: Section.connections.icon) }
                .tag(Section.connections)
            SyncView()
                .tabItem { Label(Section.sync.label, systemImage: Section.sync.icon) }
                .tag(Section.sync)
            DataView()
                .tabItem { Label(Section.data.label, systemImage: Section.data.icon) }
                .tag(Section.data)
        }
    }
}
