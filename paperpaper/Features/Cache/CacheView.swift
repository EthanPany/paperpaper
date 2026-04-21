import SwiftUI

struct CacheView: View {
    @AppStorage("cache.maxSizeMB") private var maxSizeMB: Double = 500
    @AppStorage("cache.prefetchCount") private var prefetchCount: Int = 3
    @AppStorage("cache.keepOnlyReferences") private var keepOnlyReferences: Bool = true

    @State private var currentSizeMB: Double = 0
    @State private var count: Int = 0

    var body: some View {
        Form {
            Section("Storage") {
                HStack {
                    Text("Max size")
                    Slider(value: $maxSizeMB, in: 50...5000, step: 50)
                    Text("\(Int(maxSizeMB)) MB")
                        .monospacedDigit()
                        .frame(width: 90, alignment: .trailing)
                }
                HStack {
                    Text("Pre-fetch next")
                    Slider(
                        value: Binding(
                            get: { Double(prefetchCount) },
                            set: { prefetchCount = Int($0) }
                        ),
                        in: 0...10,
                        step: 1
                    )
                    Text("\(prefetchCount)")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                Toggle("Keep only references after rotation", isOn: $keepOnlyReferences)
                    .help("When on, the cache is pruned aggressively, keeping only the current and pre-fetched images.")
            }

            Section("Stats") {
                LabeledContent("Current size", value: String(format: "%.1f MB", currentSizeMB))
                LabeledContent("Images cached", value: "\(count)")
                LabeledContent("Cache folder", value: ImageCache.shared.dir.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Section {
                Button("Refresh stats") { refresh() }
                Button("Clear image cache", role: .destructive) {
                    ImageCache.shared.clear()
                    refresh()
                }
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

#Preview {
    CacheView()
        .frame(width: 900, height: 600)
}
