import WidgetKit
import SwiftUI

@main
struct paperpaperWidgetBundle: WidgetBundle {
    var body: some Widget {
        BlurbWidget()
        ExifWidget()
        MinimalWidget()
        PhotographerWidget()
    }
}

struct PaperEntry: TimelineEntry {
    let date: Date
    let payload: WidgetPayload
}

struct PaperProvider: TimelineProvider {
    func placeholder(in context: Context) -> PaperEntry {
        PaperEntry(date: .now, payload: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (PaperEntry) -> Void) {
        completion(PaperEntry(date: .now, payload: WidgetPayload.read() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PaperEntry>) -> Void) {
        let entry = PaperEntry(date: .now, payload: WidgetPayload.read() ?? .placeholder)
        let next = Date.now.addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct BlurbWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "paperpaper.blurb", provider: PaperProvider()) { entry in
            BlurbLayout(payload: entry.payload)
                .containerBackground(for: .widget) { ThumbnailBackground(payload: entry.payload) }
        }
        .configurationDisplayName("paperpaper · Blurb")
        .description("Building name, architect, one-sentence intro.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ExifWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "paperpaper.exif", provider: PaperProvider()) { entry in
            ExifLayout(payload: entry.payload)
                .containerBackground(for: .widget) { ThumbnailBackground(payload: entry.payload) }
        }
        .configurationDisplayName("paperpaper · EXIF")
        .description("Camera, lens, aperture, ISO, and GPS from the current photo.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct MinimalWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "paperpaper.minimal", provider: PaperProvider()) { entry in
            MinimalLayout(payload: entry.payload)
                .containerBackground(for: .widget) { ThumbnailBackground(payload: entry.payload) }
        }
        .configurationDisplayName("paperpaper · Minimal")
        .description("Just the name.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct PhotographerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "paperpaper.photographer", provider: PaperProvider()) { entry in
            PhotographerLayout(payload: entry.payload)
                .containerBackground(for: .widget) { ThumbnailBackground(payload: entry.payload) }
        }
        .configurationDisplayName("paperpaper · Photographer")
        .description("Author, area, and Unsplash attribution.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ThumbnailBackground: View {
    let payload: WidgetPayload

    var body: some View {
        ZStack {
            if let image = loadImage() {
                image
                    .resizable()
                    .scaledToFill()
                LinearGradient(
                    colors: [.black.opacity(0.05), .black.opacity(0.55)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                LinearGradient(
                    colors: [Color.gray.opacity(0.4), Color.black.opacity(0.65)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }

    private func loadImage() -> Image? {
        guard let url = payload.resolvedImageURL(),
              FileManager.default.fileExists(atPath: url.path),
              let nsImage = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: nsImage)
    }
}

extension WidgetPayload {
    static let placeholder = WidgetPayload(
        unsplashID: "placeholder",
        imageFileName: "",
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
    BlurbWidget()
} timeline: {
    PaperEntry(date: .now, payload: .placeholder)
}
