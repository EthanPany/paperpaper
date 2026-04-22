import WidgetKit
import SwiftUI

@main
struct paperpaperWidgetBundle: WidgetBundle {
    var body: some Widget {
        PhotoWidget()
        CardWidget()
        ClearWidget()
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

// MARK: - Widgets

struct PhotoWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "paperpaper.photo", provider: PaperProvider()) { entry in
            PhotoLayout(payload: entry.payload)
                .containerBackground(for: .widget) {
                    PhotoBackground(payload: entry.payload)
                }
        }
        .configurationDisplayName("paperpaper · Photo")
        .description("The wallpaper as the background, with a typographic overlay.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct CardWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "paperpaper.card", provider: PaperProvider()) { entry in
            CardLayout(payload: entry.payload)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("paperpaper · Card")
        .description("A dense typographic card. Building, architect, camera, EXIF.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ClearWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "paperpaper.clear", provider: PaperProvider()) { entry in
            ClearLayout(payload: entry.payload)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("paperpaper · Clear")
        .description("Minimal, transparent. Blends into whatever's behind it.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Photo layout

private struct PhotoLayout: View {
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
                .font(.system(family == .systemSmall ? .headline : .title3, design: .serif).weight(.semibold))
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
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
            .padding(.top, family == .systemSmall ? 2 : 4)
        }
        .padding(family == .systemSmall ? 10 : 14)
        .shadow(color: .black.opacity(0.85), radius: 6, x: 0, y: 1)
    }
}

private struct PhotoBackground: View {
    let payload: WidgetPayload

    var body: some View {
        ZStack {
            if let image = loadImage() {
                image.resizable().scaledToFill()
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

// MARK: - Card layout (dense, photographer-magazine style)

private struct CardLayout: View {
    let payload: WidgetPayload
    @Environment(\.widgetFamily) private var family

    private var title: String {
        payload.buildingName?.nilIfEmpty ?? payload.area.nilIfEmpty ?? "paperpaper"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 10) {
            // Title block
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(titleSize, design: .serif).weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(family == .systemSmall ? 2 : 1)
                if let architect = payload.architect, !architect.isEmpty {
                    Text(architect)
                        .font(family == .systemSmall ? .caption2 : .caption)
                        .italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if family == .systemLarge, let sentence = payload.oneSentence, !sentence.isEmpty {
                Text(sentence)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            // Metadata rows
            VStack(alignment: .leading, spacing: 2) {
                if !payload.area.isEmpty {
                    MetaRow(label: "Location", value: payload.area, compact: family == .systemSmall)
                }
                if family != .systemSmall, let camera = payload.cameraLine {
                    MetaRow(label: "Camera", value: camera, compact: false)
                }
                if family != .systemSmall, let lens = payload.lensLine {
                    MetaRow(label: "Lens", value: lens, compact: false)
                }
                if let shot = payload.shotLine, family != .systemSmall {
                    MetaRow(label: "Exposure", value: shot, mono: true, compact: false)
                }
                if family == .systemLarge, let lat = payload.latitude, let lon = payload.longitude {
                    MetaRow(label: "GPS", value: String(format: "%.3f, %.3f", lat, lon), mono: true, compact: false)
                }
            }

            Spacer(minLength: 0)

            HStack(alignment: .firstTextBaseline) {
                if !payload.authorName.isEmpty {
                    Text(payload.authorName.uppercased())
                        .font(.system(.caption2, design: .monospaced))
                        .tracking(1.5)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let year = payload.year {
                    Text("\(year)")
                        .font(.system(.caption, design: .serif))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(family == .systemSmall ? 12 : 16)
    }

    private var titleSize: Font.TextStyle {
        switch family {
        case .systemSmall: return .callout
        case .systemLarge: return .title2
        default: return .title3
        }
    }
}

private struct MetaRow: View {
    let label: String
    let value: String
    var mono: Bool = false
    var compact: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if !compact {
                Text(label.uppercased())
                    .font(.system(.caption2, design: .default).weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                    .frame(width: 68, alignment: .leading)
            }
            Text(value)
                .font(mono ? .system(.caption2, design: .monospaced) : .caption2)
                .foregroundStyle(.primary)
                .lineLimit(compact ? 2 : 1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Clear layout (transparent, minimal)

private struct ClearLayout: View {
    let payload: WidgetPayload
    @Environment(\.widgetFamily) private var family

    private var title: String {
        payload.buildingName?.nilIfEmpty ?? payload.area.nilIfEmpty ?? "paperpaper"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .tracking(1.4)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.bottom, 4)

            Text(payload.architect ?? payload.area)
                .font(.system(titleSize, design: .serif).weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(family == .systemSmall ? 3 : 2)
                .padding(.bottom, 6)

            if family != .systemSmall, !payload.area.isEmpty {
                Text(payload.area)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if family == .systemLarge, let shot = payload.shotLine, !shot.isEmpty {
                Text(shot)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if !payload.authorName.isEmpty {
                Text("— \(payload.authorName)")
                    .font(.caption2)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(family == .systemSmall ? 12 : 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var titleSize: Font.TextStyle {
        switch family {
        case .systemSmall: return .title3
        case .systemLarge: return .largeTitle
        default: return .title
        }
    }
}

// MARK: - Helpers

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
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
        authorName: "Anders Jildén",
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

#Preview("Photo · Medium", as: .systemMedium) {
    PhotoWidget()
} timeline: {
    PaperEntry(date: .now, payload: .placeholder)
}

#Preview("Card · Medium", as: .systemMedium) {
    CardWidget()
} timeline: {
    PaperEntry(date: .now, payload: .placeholder)
}

#Preview("Card · Large", as: .systemLarge) {
    CardWidget()
} timeline: {
    PaperEntry(date: .now, payload: .placeholder)
}

#Preview("Clear · Medium", as: .systemMedium) {
    ClearWidget()
} timeline: {
    PaperEntry(date: .now, payload: .placeholder)
}
