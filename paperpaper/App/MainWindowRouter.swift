import SwiftUI

enum WindowMode: String, CaseIterable, Identifiable {
    case photo
    case settings

    var id: String { rawValue }
    var label: String { self == .photo ? "Photo" : "Settings" }
    var icon: String { self == .photo ? "photo" : "gearshape" }
}

/// Shared mode state for the single main `Window` scene. The previous
/// per-view `@State` survived close/reopen cycles, so closing while on
/// Settings meant the next "Open paperpaper…" reopened the window still on
/// Settings — the user described this as "stuck on the settings window with
/// no way back". Hoisting it lets the menu-bar button and dock-icon reopen
/// reset mode to `.photo` before the window comes forward.
@MainActor
@Observable
final class MainWindowState {
    static let shared = MainWindowState()
    var mode: WindowMode = .photo
    /// Which tab the Settings pane shows. Hoisted here (rather than living as
    /// `@State` inside SettingsPane) so other surfaces — notably the first-run
    /// checklist in NowView — can deep-link straight to a specific tab, e.g.
    /// "Open Connections" jumps to `.connections` instead of dumping the user
    /// on the default Discover tab.
    var settingsSection: SettingsPane.Section = .discover
    private init() {}
}

struct MainWindowRouter: View {
    @State private var state = MainWindowState.shared

    var body: some View {
        ZStack {
            switch state.mode {
            case .photo:
                NowView()
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            case .settings:
                SettingsPane()
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: state.mode)
        .frame(minWidth: 900, minHeight: 620)
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                Picker("", selection: Binding(
                    get: { state.mode },
                    set: { state.mode = $0 }
                )) {
                    ForEach(WindowMode.allCases) { m in
                        Label(m.label, systemImage: m.icon).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }
}
