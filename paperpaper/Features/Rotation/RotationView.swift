import SwiftUI

struct RotationView: View {
    @State private var isOn: Bool = false
    @State private var intervalMinutes: Double = 60
    @State private var dayNightSplit: Bool = false
    @State private var spaceMode: SpaceMode = .unified

    var body: some View {
        Form {
            Section("Schedule") {
                Toggle("Enable rotation", isOn: $isOn)
                HStack {
                    Text("Every")
                    Slider(value: $intervalMinutes, in: 1...720, step: 1)
                    Text("\(Int(intervalMinutes)) min")
                        .monospacedDigit()
                        .frame(width: 80, alignment: .trailing)
                }
                Toggle("Separate day / night pools", isOn: $dayNightSplit)
            }

            Section("Spaces") {
                Picker("Behavior", selection: $spaceMode) {
                    Text("Unified").tag(SpaceMode.unified)
                    Text("Per-Space").tag(SpaceMode.perSpace)
                    Text("Active only").tag(SpaceMode.activeOnly)
                }
                .pickerStyle(.radioGroup)
            }

            Section("Filters") {
                Text("Color, aspect ratio, camera, lens, focal length, country — coming next.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

enum SpaceMode: Hashable {
    case unified, perSpace, activeOnly
}

#Preview {
    RotationView()
        .frame(width: 900, height: 600)
}
