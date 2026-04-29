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
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: mode)
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
