import WidgetKit
import SwiftUI

@main
struct paperpaperWidgetBundle: WidgetBundle {
    var body: some Widget {
        paperpaperWidget()
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

struct paperpaperWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "paperpaper", provider: PaperProvider()) { entry in
            WidgetContent(payload: entry.payload)
                .containerBackground(for: .widget) {
                    WidgetBackground(payload: entry.payload)
                }
        }
        .configurationDisplayName("paperpaper")
        .description("The current wallpaper with its name and metadata.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct WidgetContent: View {
    let payload: WidgetPayload
    @Environment(\.widgetFamily) private var family

    private var title: String {
        if let n = payload.buildingName, !n.isEmpty { return n }
        if !payload.area.isEmpty { return payload.area }
        return "paperpaper"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Spacer(minLength: 0)

            Text(title)
                .font(family == .systemSmall ? .headline : .title3.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(family == .systemSmall ? 2 : 1)

            if family != .systemSmall, let architect = payload.architect, !architect.isEmpty {
                Text(architect)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
            }

            if family == .systemLarge, let sentence = payload.oneSentence, !sentence.isEmpty {
                Text(sentence)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(3)
                    .padding(.top, 2)
            }

            HStack(spacing: 8) {
                if !payload.area.isEmpty {
                    Label(payload.area, systemImage: "location")
                        .labelStyle(.titleAndIcon)
                }
                if family == .systemLarge, let shot = payload.shotLine, !shot.isEmpty {
                    Text("·")
                    Text(shot)
                }
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.8))
            .lineLimit(1)
            .padding(.top, family == .systemSmall ? 2 : 4)
        }
        .padding(family == .systemSmall ? 12 : 16)
        .shadow(color: .black.opacity(0.85), radius: 6, x: 0, y: 1)
    }
}

private struct WidgetBackground: View {
    let payload: WidgetPayload

    var body: some View {
        ZStack {
            if let image = loadImage() {
                image
                    .resizable()
                    .scaledToFill()
                LinearGradient(
                    colors: [.black.opacity(0), .black.opacity(0.65)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 0.09, green: 0.12, blue: 0.20),
                        Color(red: 0.16, green: 0.19, blue: 0.28),
                        Color(red: 0.32, green: 0.25, blue: 0.20),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "building.columns")
                    .font(.system(size: 60, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.12))
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
    paperpaperWidget()
} timeline: {
    PaperEntry(date: .now, payload: .placeholder)
}
