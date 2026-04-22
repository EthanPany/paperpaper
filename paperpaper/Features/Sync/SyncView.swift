import SwiftUI
import SwiftData

struct SyncView: View {
    @AppStorage("sync.enabled") private var syncEnabled: Bool = false
    @AppStorage("sync.settings") private var syncSettings: Bool = true
    @AppStorage("sync.history") private var syncHistory: Bool = true
    @AppStorage("sync.enrichment") private var syncEnrichment: Bool = true
    @AppStorage("sync.keys") private var syncKeys: Bool = false

    @Query private var prefs: [SyncPrefs]
    private var record: SyncPrefs { prefs.first ?? Store.shared.syncPrefs() }

    var body: some View {
        Form {
            Section {
                Toggle("Enable iCloud sync", isOn: $syncEnabled)
                    .onChange(of: syncEnabled) { _, newValue in
                        record.enabled = newValue
                        try? Store.shared.context.save()
                    }
                Text(syncEnabled
                     ? "Quit and relaunch paperpaper after toggling. The SwiftData store is reconfigured at launch."
                     : "Off: all data stays on this Mac only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Last sync", value: record.lastSyncAt?.formatted() ?? "—")
            }

            Section("What to sync (when enabled)") {
                Toggle("Settings (rotation, filters, overlay)", isOn: $syncSettings)
                    .disabled(!syncEnabled)
                Toggle("History and favorites", isOn: $syncHistory)
                    .disabled(!syncEnabled)
                Toggle("Enrichment cache (Ollama results)", isOn: $syncEnrichment)
                    .disabled(!syncEnabled)
                Toggle("API keys (via iCloud Keychain)", isOn: $syncKeys)
                    .disabled(!syncEnabled)
                    .onChange(of: syncKeys) { _, newValue in
                        if let key = KeychainService.shared.get(.unsplashAccessKey) {
                            KeychainService.shared.set(key, for: .unsplashAccessKey, syncable: newValue)
                        }
                        if let auth = KeychainService.shared.get(.ollamaAuthHeader) {
                            KeychainService.shared.set(auth, for: .ollamaAuthHeader, syncable: newValue)
                        }
                    }
            }

            Section("Requirements") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("• iCloud capability on the paperpaper target with a CloudKit container must be set up in Xcode.")
                    Text("• The Mac must be signed into iCloud.")
                    Text("• Not synced: image bytes, current-wallpaper state, and Space identifiers (all per-device).")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    SyncView()
        .modelContainer(Store.shared.container)
        .frame(width: 900, height: 600)
}
