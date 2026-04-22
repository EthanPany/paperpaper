import SwiftUI

enum WindowMode: String, CaseIterable, Identifiable {
    case photo
    case settings

    var id: String { rawValue }
    var label: String { self == .photo ? "Photo" : "Settings" }
    var icon: String { self == .photo ? "photo" : "gearshape" }
}

struct MainWindowRouter: View {
    @State private var mode: WindowMode = .photo

    var body: some View {
        ZStack {
            switch mode {
            case .photo:
                NowView()
            case .settings:
                SettingsPane()
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                Picker("", selection: $mode) {
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
