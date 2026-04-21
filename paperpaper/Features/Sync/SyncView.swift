import SwiftUI

struct SyncView: View {
    @State private var enabled: Bool = false
    @State private var syncSettings: Bool = true
    @State private var syncHistory: Bool = true
    @State private var syncEnrichment: Bool = true
    @State private var syncKeys: Bool = false

    var body: some View {
        Form {
            Section("iCloud") {
                Toggle("Enable iCloud sync", isOn: $enabled)
                LabeledContent("Status", value: enabled ? "—" : "Off")
                LabeledContent("Last sync", value: "—")
            }

            Section("What to sync") {
                Toggle("Settings (rotation, filters, overlay)", isOn: $syncSettings)
                    .disabled(!enabled)
                Toggle("History and favorites", isOn: $syncHistory)
                    .disabled(!enabled)
                Toggle("Enrichment cache (Ollama results)", isOn: $syncEnrichment)
                    .disabled(!enabled)
                Toggle("API keys (via iCloud Keychain)", isOn: $syncKeys)
                    .disabled(!enabled)
            }

            Section {
                Button("Force sync now") {}
                    .disabled(!enabled)
                Button("Replace remote with this device", role: .destructive) {}
                    .disabled(!enabled)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    SyncView()
        .frame(width: 900, height: 600)
}
