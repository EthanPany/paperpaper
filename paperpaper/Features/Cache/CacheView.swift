import SwiftUI

/// Combined Data tab: cache + sync in one place.
struct DataView: View {
    var body: some View {
        TabView {
            CachePane()
                .tabItem { Label("Cache", systemImage: "externaldrive") }
            SyncPane()
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath.icloud") }
        }
    }
}

struct CachePane: View {
    @AppStorage("cache.maxSizeMB") private var maxSizeMB: Double = 500
    @AppStorage("cache.prefetchCount") private var prefetchCount: Int = 3
    @AppStorage("cache.keepOnlyReferences") private var keepOnlyReferences: Bool = true

    @State private var currentSizeMB: Double = 0
    @State private var count: Int = 0
    @State private var showAdvanced: Bool = false

    var body: some View {
        Form {
            Section("Storage") {
                Stepper(value: Binding(
                    get: { Int(maxSizeMB) },
                    set: { maxSizeMB = Double($0) }
                ), in: 50...10000, step: 50) {
                    HStack {
                        Text("Max size")
                        Spacer()
                        Text("\(Int(maxSizeMB)) MB")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Stepper(value: $prefetchCount, in: 0...10) {
                    HStack {
                        Text("Pre-fetch next")
                        Spacer()
                        Text("\(prefetchCount)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Keep only references after rotation", isOn: $keepOnlyReferences)
            }

            Section("Stats") {
                LabeledContent("Current size", value: String(format: "%.1f MB", currentSizeMB))
                LabeledContent("Images cached", value: "\(count)")
                Button("Refresh") { refresh() }
                    .buttonStyle(.glass)
            }

            Section {
                Button("Clear image cache", role: .destructive) {
                    ImageCache.shared.clear()
                    refresh()
                }
            }

            DisclosureGroup(isExpanded: $showAdvanced) {
                LabeledContent("Cache folder") {
                    Text(ImageCache.shared.dir.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            } label: {
                Label("Advanced", systemImage: "ellipsis.circle")
            }
        }
        .formStyle(.grouped)
        .task { refresh() }
    }

    private func refresh() {
        let bytes = ImageCache.shared.currentSizeBytes()
        currentSizeMB = Double(bytes) / (1024 * 1024)
        count = ImageCache.shared.currentCount()
    }
}

struct CacheView: View {
    var body: some View { CachePane() }
}

#Preview {
    DataView().frame(width: 720, height: 600)
}
