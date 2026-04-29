import SwiftUI

/// iCloud sync settings.
///
/// Config-only model: schedule + currently-applied photo ID flow through
/// NSUbiquitousKeyValueStore. Image bytes and enrichment text are NOT synced
/// — each device runs its own local Ollama and re-downloads from Unsplash.
/// Exactly one device is "primary" at any time; others mirror.
struct SyncView: View {
    @State private var coordinator = iCloudSyncCoordinator.shared

    var body: some View {
        Form {
            Section("iCloud sync") {
                Toggle("Sync paperpaper across your iCloud devices",
                       isOn: $coordinator.isEnabled)
                Text("Schedules and the currently-applied photo are mirrored. Image bytes stay local — each Mac fetches its own copy from Unsplash and runs its own Ollama enrichment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("This Mac") {
                LabeledContent("Device name", value: coordinator.deviceName)
                LabeledContent("Status") {
                    statusBadge
                }
                if coordinator.isEnabled, !coordinator.isPrimaryHere {
                    Button {
                        coordinator.makeThisDevicePrimary()
                    } label: {
                        Label("Make this Mac primary", systemImage: "star")
                    }
                    .buttonStyle(.glassProminent)
                }
                if let last = coordinator.lastSyncAt {
                    LabeledContent("Last sync", value: last.formatted(date: .abbreviated, time: .shortened))
                }
                if let err = coordinator.lastError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("How this works")
                        .font(.callout.weight(.medium))
                    Text("• The primary Mac drives the rotation schedule and chooses photos.\n• Other Macs detect changes via iCloud Key-Value Store and mirror them — they never overwrite the primary's choices.\n• When you make this Mac primary, the previous primary stops publishing on its next iCloud refresh.\n• If you sign out of iCloud or disable sync, each Mac becomes independent again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if !coordinator.isEnabled {
            Text("Off").foregroundStyle(.secondary)
        } else if coordinator.isPrimaryHere {
            Label("Primary", systemImage: "star.fill")
                .foregroundStyle(.green)
        } else if let name = coordinator.primaryDeviceName, !name.isEmpty {
            Label("Mirroring \(name)", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        } else {
            Label("Looking for primary…", systemImage: "ellipsis")
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    SyncView().frame(width: 720, height: 600)
}
