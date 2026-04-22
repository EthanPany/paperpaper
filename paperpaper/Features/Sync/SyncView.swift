import SwiftUI
import SwiftData

struct SyncPane: View {
    @AppStorage("sync.enabled") private var syncEnabled: Bool = false
    @AppStorage("sync.settings") private var syncSettings: Bool = true
    @AppStorage("sync.history") private var syncHistory: Bool = true
    @AppStorage("sync.enrichment") private var syncEnrichment: Bool = true
    @AppStorage("sync.keys") private var syncKeys: Bool = false

    @Query private var prefs: [SyncPrefs]
    @State private var showAdvanced: Bool = false

    private var record: SyncPrefs { prefs.first ?? Store.shared.syncPrefs() }

    var body: some View {
        Form {
            Section("iCloud sync") {
                Toggle("Enable iCloud sync", isOn: $syncEnabled)
                    .onChange(of: syncEnabled) { _, newValue in
                        record.enabled = newValue
                        try? Store.shared.context.save()
                    }
                Text(syncEnabled
                     ? "Quit and relaunch paperpaper. The SwiftData store is reconfigured at launch."
                     : "Off: all data stays on this Mac only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Last sync", value: record.lastSyncAt?.formatted() ?? "—")
            }

            Section("What to sync") {
                Toggle("Settings", isOn: $syncSettings).disabled(!syncEnabled)
                Toggle("History and favorites", isOn: $syncHistory).disabled(!syncEnabled)
                Toggle("Enrichment cache", isOn: $syncEnrichment).disabled(!syncEnabled)
                Toggle("API keys (iCloud Keychain)", isOn: $syncKeys)
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

            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("• iCloud capability (CloudKit) must be enabled on the paperpaper target in Xcode.")
                    Text("• Not synced: image bytes, current-wallpaper state, Space identifiers.")
                    Text("• When off, SwiftData store is local-only (cloudKitDatabase: .none).")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } label: {
                Label("Advanced", systemImage: "ellipsis.circle")
            }
        }
        .formStyle(.grouped)
    }
}

struct SyncView: View {
    var body: some View { SyncPane() }
}

#Preview {
    SyncPane()
        .modelContainer(Store.shared.container)
        .frame(width: 720, height: 600)
}
