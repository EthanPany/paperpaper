import SwiftUI
#if os(macOS)
import AppKit
#endif

struct AdvancedView: View {
    @AppStorage("log.level") private var logLevelRaw: String = LogLevel.info.rawValue
    @AppStorage("network.timeoutSeconds") private var networkTimeout: Double = 20
    @AppStorage("network.retryCount") private var retryCount: Double = 3
    @AppStorage("app.hideDockIcon") private var hideDockIcon: Bool = false

    @State private var resetConfirmation: Bool = false

    private var logLevel: LogLevel {
        LogLevel(rawValue: logLevelRaw) ?? .info
    }

    var body: some View {
        Form {
            Section("Logging") {
                Picker("Level", selection: Binding(
                    get: { logLevel },
                    set: { logLevelRaw = $0.rawValue }
                )) {
                    Text("Error").tag(LogLevel.error)
                    Text("Warn").tag(LogLevel.warn)
                    Text("Info").tag(LogLevel.info)
                    Text("Debug").tag(LogLevel.debug)
                }
                Button("Export diagnostic bundle") { exportDiagnostics() }
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
                Toggle("Menu-bar only (hide Dock icon)", isOn: $hideDockIcon)
                    .onChange(of: hideDockIcon) { _, newValue in
                        #if os(macOS)
                        NSApp.setActivationPolicy(newValue ? .accessory : .regular)
                        #endif
                    }
            }

            Section("Danger zone") {
                Button("Delete all local photos and history", role: .destructive) {
                    Store.shared.deleteAllLocalData()
                    ImageCache.shared.clear()
                }
                Button("Reset all settings", role: .destructive) {
                    resetConfirmation = true
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Reset all settings to defaults?",
            isPresented: $resetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) { resetAllSettings() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func resetAllSettings() {
        let keys = [
            "log.level", "network.timeoutSeconds", "network.retryCount", "app.hideDockIcon",
            "cache.maxSizeMB", "cache.prefetchCount", "cache.keepOnlyReferences",
            "ollama.url", "ollama.model", "ollama.temperature", "ollama.timeoutSeconds", "ollama.webSearch",
        ]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    private func exportDiagnostics() {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "paperpaper-diagnostics.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let payload: [String: Any] = [
            "version": "1.0",
            "exportedAt": ISO8601DateFormatter().string(from: .now),
            "settings": userDefaultsSnapshot(),
            "cacheSizeBytes": ImageCache.shared.currentSizeBytes(),
            "cacheCount": ImageCache.shared.currentCount(),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted) {
            try? data.write(to: url)
        }
        #endif
    }

    private func userDefaultsSnapshot() -> [String: Any] {
        let keys = [
            "log.level", "network.timeoutSeconds", "network.retryCount", "app.hideDockIcon",
            "cache.maxSizeMB", "cache.prefetchCount", "cache.keepOnlyReferences",
            "ollama.url", "ollama.model", "ollama.temperature", "ollama.timeoutSeconds", "ollama.webSearch",
        ]
        var dict: [String: Any] = [:]
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key) {
                dict[key] = value
            }
        }
        return dict
    }
}

#Preview {
    AdvancedView()
        .frame(width: 900, height: 600)
}
