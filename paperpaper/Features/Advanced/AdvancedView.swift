import SwiftUI

struct AdvancedView: View {
    @State private var logLevel: LogLevel = .info
    @State private var networkTimeout: Double = 20
    @State private var retryCount: Double = 3
    @State private var hideDockIcon: Bool = false

    var body: some View {
        Form {
            Section("Logging") {
                Picker("Level", selection: $logLevel) {
                    Text("Error").tag(LogLevel.error)
                    Text("Warn").tag(LogLevel.warn)
                    Text("Info").tag(LogLevel.info)
                    Text("Debug").tag(LogLevel.debug)
                }
                Button("Export diagnostic bundle") {}
            }

            Section("Networking") {
                HStack {
                    Text("Timeout")
                    Slider(value: $networkTimeout, in: 5...120, step: 1)
                    Text("\(Int(networkTimeout)) s")
                        .monospacedDigit()
                        .frame(width: 60, alignment: .trailing)
                }
                HStack {
                    Text("Retries")
                    Slider(value: $retryCount, in: 0...10, step: 1)
                    Text("\(Int(retryCount))")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }

            Section("App") {
                Toggle("Hide Dock icon (menu bar only)", isOn: $hideDockIcon)
                Text("Takes effect after relaunch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Reset all settings", role: .destructive) {}
            }
        }
        .formStyle(.grouped)
    }
}

enum LogLevel: Hashable {
    case error, warn, info, debug
}

#Preview {
    AdvancedView()
        .frame(width: 900, height: 600)
}
