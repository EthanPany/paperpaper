import SwiftUI

/// Settings content rendered inside the main window (not a separate Settings scene).
struct SettingsPane: View {
    enum Section: String, Hashable, CaseIterable {
        case discover, library, schedule, display, intelligence, source, data

        var label: String {
            switch self {
            case .discover: return "Discover"
            case .library: return "Library"
            case .schedule: return "Schedule"
            case .display: return "Display"
            case .intelligence: return "Intelligence"
            case .source: return "Source"
            case .data: return "Data"
            }
        }

        var icon: String {
            switch self {
            case .discover: return "sparkles"
            case .library: return "square.grid.2x2"
            case .schedule: return "clock.arrow.2.circlepath"
            case .display: return "textformat"
            case .intelligence: return "brain"
            case .source: return "link"
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
            OverlayView()
                .tabItem { Label(Section.display.label, systemImage: Section.display.icon) }
                .tag(Section.display)
            IntelligenceView()
                .tabItem { Label(Section.intelligence.label, systemImage: Section.intelligence.icon) }
                .tag(Section.intelligence)
            SourceView()
                .tabItem { Label(Section.source.label, systemImage: Section.source.icon) }
                .tag(Section.source)
            DataView()
                .tabItem { Label(Section.data.label, systemImage: Section.data.icon) }
                .tag(Section.data)
        }
    }
}
