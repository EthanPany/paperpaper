import WidgetKit
import SwiftUI

@main
struct paperpaperWidgetBundle: WidgetBundle {
    var body: some Widget {
        paperpaperWidget()
    }
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PaperEntry {
        PaperEntry(date: .now, configuration: ConfigurationAppIntent(), payload: .placeholder)
    }

    func snapshot(for configuration: ConfigurationAppIntent, in context: Context) async -> PaperEntry {
        let payload = WidgetPayload.read() ?? .placeholder
        return PaperEntry(date: .now, configuration: configuration, payload: payload)
    }

    func timeline(for configuration: ConfigurationAppIntent, in context: Context) async -> Timeline<PaperEntry> {
        let payload = WidgetPayload.read() ?? .placeholder
        let entry = PaperEntry(date: .now, configuration: configuration, payload: payload)
        let next = Date.now.addingTimeInterval(15 * 60)
        return Timeline(entries: [entry], policy: .after(next))
    }
}

struct PaperEntry: TimelineEntry {
    let date: Date
    let configuration: ConfigurationAppIntent
    let payload: WidgetPayload
}

struct paperpaperWidgetEntryView: View {
    var entry: Provider.Entry

    var body: some View {
        switch entry.configuration.layout {
        case .blurb: BlurbLayout(payload: entry.payload)
        case .exif: ExifLayout(payload: entry.payload)
        case .minimal: MinimalLayout(payload: entry.payload)
        case .photographer: PhotographerLayout(payload: entry.payload)
        }
    }
}

struct paperpaperWidget: Widget {
    let kind: String = "paperpaperWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ConfigurationAppIntent.self, provider: Provider()) { entry in
            paperpaperWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) {
                    ThumbnailBackground(payload: entry.payload)
                }
        }
        .configurationDisplayName("paperpaper")
        .description("Current wallpaper + metadata.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct ThumbnailBackground: View {
    let payload: WidgetPayload

    var body: some View {
        ZStack {
            if let image = loadImage() {
                image.resizable().scaledToFill()
                LinearGradient(
                    colors: [.black.opacity(0.05), .black.opacity(0.55)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                LinearGradient(
                    colors: [Color.gray.opacity(0.35), Color.black.opacity(0.6)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }

    private func loadImage() -> Image? {
        guard !payload.imageFilePath.isEmpty,
              FileManager.default.fileExists(atPath: payload.imageFilePath),
              let nsImage = NSImage(contentsOfFile: payload.imageFilePath) else { return nil }
        return Image(nsImage: nsImage)
    }
}

extension WidgetPayload {
    static let placeholder = WidgetPayload(
        unsplashID: "placeholder",
        imageFilePath: "",
        buildingName: "Sagrada Família",
        architect: "Antoni Gaudí",
        year: 1882,
        style: "Gothic revival",
        oneSentence: "A basilica in Barcelona, under construction since 1882.",
        area: "Barcelona, Spain",
        authorName: "Photographer",
        authorProfileURLString: nil,
        cameraLine: "Fujifilm X-T4",
        lensLine: "XF 23mm f/1.4",
        shotLine: "23mm · f/8 · 1/250s · ISO 200",
        latitude: 41.4036,
        longitude: 2.1744,
        takenAtSeconds: nil,
        updatedAtSeconds: Date.now.timeIntervalSince1970
    )
}

#Preview(as: .systemMedium) {
    paperpaperWidget()
} timeline: {
    PaperEntry(date: .now, configuration: ConfigurationAppIntent(), payload: .placeholder)
}
