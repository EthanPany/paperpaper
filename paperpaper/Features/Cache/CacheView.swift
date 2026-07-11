import SwiftUI

/// Data tab: just the cache pane. Sync used to live here too, but it's now
/// a top-level Settings tab.
struct DataView: View {
    var body: some View {
        CachePane()
    }
}

struct CachePane: View {
    @AppStorage("cache.maxImages") private var maxImages: Int = WallpaperApplier.defaultMaxCachedImages
    @AppStorage("cache.prefetchCount") private var prefetchCount: Int = 0

    #if os(macOS)
    @StateObject private var loginItem = LoginItemController.shared
    #endif

    @State private var currentSizeMB: Double = 0
    @State private var count: Int = 0
    @State private var showAdvanced: Bool = false
    @State private var widgetDiagnostics: WidgetDiagnostics = .init()

    var body: some View {
        Form {
            #if os(macOS)
            Section {
                Toggle("Open at login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                if let err = loginItem.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("Launch paperpaper automatically when you sign in to your Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Startup")
            }
            #endif

            Section("Storage") {
                Stepper(value: $maxImages, in: 1...200) {
                    HStack {
                        Text("Max images")
                        Spacer()
                        Text("\(maxImages)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Keeps the \(maxImages) most-recent wallpaper images on disk for offline use, then drops the oldest. With \u{201C}No repeats\u{201D} on, every rotation downloads a fresh photo anyway, so the cache stays small. Photo details stay in the library either way — a photo is never re-described if it comes back around.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper(value: $prefetchCount, in: 0...10) {
                    HStack {
                        Text("Pre-fetch next")
                        Spacer()
                        Text(prefetchCount == 0 ? "Off" : "\(prefetchCount)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Text(prefetchCount == 0
                     ? "Off — every rotation grabs one fresh photo for your current location."
                     : "Warms the next \(prefetchCount) photo(s) in the background. Higher values can serve older, less location-specific photos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .task {
            refresh()
            #if os(macOS)
            loginItem.refresh()
            #endif
        }
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
