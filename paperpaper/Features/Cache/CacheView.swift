import SwiftUI

/// Data tab: just the cache pane. Sync used to live here too, but it's now
/// a top-level Settings tab.
struct DataView: View {
    var body: some View {
        CachePane()
    }
}

struct CachePane: View {
    @AppStorage("cache.maxSizeMB") private var maxSizeMB: Double = 500
    @AppStorage("cache.prefetchCount") private var prefetchCount: Int = 3
    @AppStorage("cache.keepOnlyReferences") private var keepOnlyReferences: Bool = true

    @State private var currentSizeMB: Double = 0
    @State private var count: Int = 0
    @State private var showAdvanced: Bool = false
    @State private var widgetDiagnostics: WidgetDiagnostics = .init()

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

            Section("Widget") {
                Button {
                    WallpaperApplier.shared.syncWidgetFromCurrent()
                    refresh()
                } label: {
                    Label("Refresh widget now", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.glass)
                LabeledContent("Payload written", value: widgetDiagnostics.lastWriteDisplay)
                LabeledContent("Widget last read", value: widgetDiagnostics.lastReadDisplay)
                if !widgetDiagnostics.lastReadStage.isEmpty {
                    LabeledContent("Last read stage", value: widgetDiagnostics.lastReadStage)
                }
                if widgetDiagnostics.lastReadDisplay == "never" {
                    Text("If 'Widget last read' stays 'never' after you add the paperpaper widget to the Desktop and press Refresh, the widget process isn't loading your build. Try: killall chronod, then remove + re-add the widget.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Widget last read confirms the extension process is alive and reading the App Group container.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
        widgetDiagnostics = WidgetDiagnostics.load()
    }
}

struct WidgetDiagnostics {
    var lastWriteDisplay: String = "never"
    var lastReadDisplay: String = "never"
    var lastReadStage: String = ""

    static func load() -> WidgetDiagnostics {
        var out = WidgetDiagnostics()
        let fm = FileManager.default

        if let container = fm.containerURL(forSecurityApplicationGroupIdentifier: WidgetPayload.appGroup) {
            let payloadURL = container.appending(path: "widget/payload.json")
            if let attrs = try? fm.attributesOfItem(atPath: payloadURL.path),
               let modified = attrs[.modificationDate] as? Date {
                out.lastWriteDisplay = relativeDescription(for: modified)
            }
            let breadcrumbURL = container.appending(path: "widget/last_read.json")
            if let data = try? Data(contentsOf: breadcrumbURL),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let ts = obj["readAt"] as? Double {
                    out.lastReadDisplay = relativeDescription(for: Date(timeIntervalSince1970: ts))
                }
                if let stage = obj["stage"] as? String {
                    out.lastReadStage = stage
                }
            }
        }
        return out
    }

    private static func relativeDescription(for date: Date) -> String {
        let elapsed = Date.now.timeIntervalSince(date)
        if elapsed < 0 { return date.formatted() }
        if elapsed < 60 { return "\(Int(elapsed)) s ago" }
        if elapsed < 3600 { return "\(Int(elapsed / 60)) min ago" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600)) h ago" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

struct CacheView: View {
    var body: some View { CachePane() }
}

#Preview {
    DataView().frame(width: 720, height: 600)
}
