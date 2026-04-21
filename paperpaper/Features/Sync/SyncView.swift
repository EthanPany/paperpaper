import SwiftUI
import SwiftData

struct SyncView: View {
    @Query private var prefs: [SyncPrefs]

    private var sync: SyncPrefs { prefs.first ?? Store.shared.syncPrefs() }

    var body: some View {
        Form {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("iCloud sync is a build-time capability.").font(.subheadline)
                        Text("To turn it on, add the iCloud capability (CloudKit) to the app in Xcode and rebuild. The toggles below persist your preference and drive the CloudKit-backed ModelConfiguration on next launch.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "icloud")
                }
            }

            Section("iCloud") {
                Toggle("Enable iCloud sync (on next launch)", isOn: Binding(
                    get: { sync.enabled },
                    set: { sync.enabled = $0; save() }
                ))
                LabeledContent("Last sync", value: sync.lastSyncAt?.formatted() ?? "—")
            }

            Section("What to sync") {
                Toggle("Settings (rotation, filters, overlay)", isOn: Binding(
                    get: { sync.syncSettings },
                    set: { sync.syncSettings = $0; save() }
                ))
                .disabled(!sync.enabled)
                Toggle("History and favorites", isOn: Binding(
                    get: { sync.syncHistory },
                    set: { sync.syncHistory = $0; save() }
                ))
                .disabled(!sync.enabled)
                Toggle("Enrichment cache (Ollama results)", isOn: Binding(
                    get: { sync.syncEnrichment },
                    set: { sync.syncEnrichment = $0; save() }
                ))
                .disabled(!sync.enabled)
                Toggle("API keys (via iCloud Keychain)", isOn: Binding(
                    get: { sync.syncKeys },
                    set: { sync.syncKeys = $0; save() }
                ))
                .disabled(!sync.enabled)
            }

            Section("To enable in Xcode") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Select the paperpaper target → Signing & Capabilities.")
                    Text("2. Add capability: iCloud. Check CloudKit and pick/create an iCloud container (e.g. iCloud.ep.paperpaper).")
                    Text("3. In paperpaperApp.swift, switch to ModelConfiguration(… cloudKitDatabase: .automatic).")
                    Text("4. Rebuild. SwiftData + CloudKit will sync models that are all-optional or defaulted — which this project's models are.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        try? Store.shared.context.save()
    }
}

#Preview {
    SyncView()
        .modelContainer(Store.shared.container)
        .frame(width: 900, height: 600)
}
