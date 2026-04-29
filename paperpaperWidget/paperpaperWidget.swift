import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Configuration

/// User-pickable focus per widget instance. Photography emphasises the
/// photographer + camera. Architecture emphasises the building + architect.
enum WidgetContentMode: String, AppEnum {
    case photography
    case architecture

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Focus")
    }

    static var caseDisplayRepresentations: [WidgetContentMode: DisplayRepresentation] {
        [
            .photography: DisplayRepresentation(title: "Photography", subtitle: "Photographer, camera, exposure"),
            .architecture: DisplayRepresentation(title: "Architecture", subtitle: "Building, architect, year"),
        ]
    }
}

struct PaperWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "paperpaper widget" }
    static var description: IntentDescription {
        IntentDescription("Pick what the widget focuses on. Architecture mode falls back to photography info if no building is confidently identified.")
    }

    @Parameter(title: "Focus", default: .photography)
    var mode: WidgetContentMode

    init() {}
}

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
    let mode: WidgetContentMode
}

struct PaperProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PaperEntry {
        PaperEntry(date: .now, payload: .placeholder, mode: .photography)
    }

    func snapshot(for configuration: PaperWidgetIntent, in context: Context) async -> PaperEntry {
        PaperEntry(date: .now, payload: WidgetPayload.read() ?? .placeholder, mode: configuration.mode)
    }

    func timeline(for configuration: PaperWidgetIntent, in context: Context) async -> Timeline<PaperEntry> {
        let entry = PaperEntry(date: .now, payload: WidgetPayload.read() ?? .placeholder, mode: configuration.mode)
        let next = Date.now.addingTimeInterval(15 * 60)
        return Timeline(entries: [entry], policy: .after(next))
    }
}

// MARK: - Widgets

struct PhotoWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "paperpaper.photo", intent: PaperWidgetIntent.self, provider: PaperProvider()) { entry in
            PhotoLayout(payload: entry.payload, mode: entry.mode)
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
        AppIntentConfiguration(kind: "paperpaper.card", intent: PaperWidgetIntent.self, provider: PaperProvider()) { entry in
            CardLayout(payload: entry.payload, mode: entry.mode)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("paperpaper · Card")
        .description("A dense typographic card. Building, architect, camera, EXIF.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ClearWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "paperpaper.clear", intent: PaperWidgetIntent.self, provider: PaperProvider()) { entry in
            ClearLayout(payload: entry.payload, mode: entry.mode)
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
    let mode: WidgetContentMode
    @Environment(\.widgetFamily) private var family

    private var content: ModeContent { ModeContent.resolve(mode: mode, payload: payload, family: family) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Spacer(minLength: 0)
            Text(content.title)
                .font(.system(family == .systemSmall ? .headline : .title3, design: .serif).weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .truncationMode(.tail)
                .minimumScaleFactor(0.85)
            if family != .systemSmall, let eyebrow = content.eyebrow, !eyebrow.isEmpty {
                Text(eyebrow)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
            }
            if family != .systemSmall, let caption = content.caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(family == .systemLarge ? 6 : 2)
                    .padding(.top, 2)
            }
            HStack(spacing: 8) {
                if let footer = content.footer, !footer.isEmpty {
                    Label(footer, systemImage: content.footerIcon)
                        .labelStyle(.titleAndIcon)
                }
                if family == .systemLarge, let extra = content.footerExtra, !extra.isEmpty {
                    Text("·")
                    Text(extra)
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
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        ZStack {
            if let image = loadImage() {
                image.resizable().scaledToFill()
                // Skip the dark gradient under .accented / .vibrant widget
                // rendering modes (Tinted style on macOS 26) — the system
                // already tints foreground content for legibility, and our
                // gradient just creates a muddy double-darkening.
                if renderingMode == .fullColor {
                    LinearGradient(
                        colors: [.black.opacity(0), .black.opacity(0.65)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
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
    let mode: WidgetContentMode
    @Environment(\.widgetFamily) private var family

    private var content: ModeContent { ModeContent.resolve(mode: mode, payload: payload, family: family) }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 10) {
            VStack(alignment: .leading, spacing: family == .systemSmall ? 3 : 2) {
                Text(content.title)
                    .font(.system(titleSize, design: .serif).weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.85)
                if let eyebrow = content.eyebrow, !eyebrow.isEmpty {
                    Text(eyebrow)
                        .font(family == .systemSmall ? .caption2 : .caption)
                        .italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(family == .systemSmall ? 2 : 1)
                }
            }

            if family != .systemSmall, let caption = content.caption, !caption.isEmpty {
                Text(caption)
                    .font(family == .systemLarge ? .footnote : .caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(family == .systemLarge ? 8 : 3)
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(content.cardRows(family: family), id: \.label) { row in
                    MetaRow(label: row.label, value: row.value, mono: row.mono, compact: family == .systemSmall)
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
                if let trailing = content.cardTrailing {
                    Text(trailing)
                        .font(.system(.caption, design: .serif))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(family == .systemSmall ? 12 : 16)
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.42),
                            .white.opacity(0.14),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        }
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.20),
                            .clear,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(height: family == .systemSmall ? 18 : 24)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .allowsHitTesting(false)
        }
        .glassEffect(.regular.tint(.white.opacity(0.18)), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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
    let mode: WidgetContentMode
    @Environment(\.widgetFamily) private var family

    private var content: ModeContent { ModeContent.resolve(mode: mode, payload: payload, family: family) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text((content.eyebrow ?? "Wallpaper").uppercased())
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .tracking(1.4)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.bottom, 4)

            Text(content.title)
                .font(.system(titleSize, design: .serif).weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.tail)
                .minimumScaleFactor(0.85)
                .padding(.bottom, 6)

            if family != .systemSmall, let footer = content.footer, !footer.isEmpty {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if family == .systemLarge, let extra = content.footerExtra, !extra.isEmpty {
                Text(extra)
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

// MARK: - Mode-resolved content

/// Single source of truth for "given a mode + payload, what goes in each
/// text slot?" Each layout reads from this so the photography/architecture
/// distinction stays consistent across Photo, Card, and Clear styles.
private struct ModeContent {
    var title: String
    var eyebrow: String?
    var caption: String?
    var footer: String?
    var footerIcon: String
    var footerExtra: String?
    var cardTrailing: String?
    var cardRowsPhoto: [Row]
    var cardRowsArch: [Row]
    private var mode: WidgetContentMode

    struct Row { let label: String; let value: String; let mono: Bool }

    func cardRows(family: WidgetFamily) -> [Row] {
        let base = mode == .photography ? cardRowsPhoto : cardRowsArch
        if family == .systemSmall {
            return Array(base.prefix(2))
        }
        return base
    }

    static func resolve(mode: WidgetContentMode, payload: WidgetPayload, family: WidgetFamily) -> ModeContent {
        switch mode {
        case .photography:
            return photographyContent(payload: payload, family: family)
        case .architecture:
            return architectureContent(payload: payload, family: family)
        }
    }

    private static func photographyContent(payload: WidgetPayload, family: WidgetFamily) -> ModeContent {
        let place = payload.bestTitle
        let camera = payload.cameraLine
        let lens = payload.lensLine
        let shot = payload.shotLine

        var rows: [Row] = []
        if let location = payload.bestFooter ?? payload.area.nilIfEmpty {
            rows.append(Row(label: "Location", value: location, mono: false))
        }
        if let c = camera { rows.append(Row(label: "Camera", value: c, mono: false)) }
        if let l = lens { rows.append(Row(label: "Lens", value: l, mono: false)) }
        if let s = shot { rows.append(Row(label: "Exposure", value: s, mono: true)) }
        if let lat = payload.latitude, let lon = payload.longitude {
            rows.append(Row(label: "GPS", value: String(format: "%.3f, %.3f", lat, lon), mono: true))
        }

        let trailing: String? = {
            guard let secs = payload.takenAtSeconds else { return nil }
            let year = Calendar.current.component(.year, from: Date(timeIntervalSince1970: secs))
            return "\(year)"
        }()

        return ModeContent(
            title: place,
            eyebrow: payload.authorName.isEmpty ? nil : payload.authorName.uppercased(),
            caption: nil,
            footer: camera ?? payload.bestFooter,
            footerIcon: camera != nil ? "camera" : "location",
            footerExtra: shot,
            cardTrailing: trailing,
            cardRowsPhoto: rows,
            cardRowsArch: [],
            mode: .photography
        )
    }

    private static func architectureContent(payload: WidgetPayload, family: WidgetFamily) -> ModeContent {
        // Architecture mode: prefer building name as title; if enrichment
        // returned nothing (low confidence), bestTitle already falls back to
        // city / area, so we degrade gracefully into "place mode" without a
        // separate code path.
        let title = payload.bestTitle
        let eyebrow = payload.bestEyebrow

        var rows: [Row] = []
        if let style = payload.style?.nilIfEmpty {
            rows.append(Row(label: "Style", value: style, mono: false))
        }
        if let year = payload.year {
            rows.append(Row(label: "Year", value: "\(year)", mono: false))
        }
        if let location = payload.bestFooter ?? payload.area.nilIfEmpty {
            rows.append(Row(label: "Location", value: location, mono: false))
        }
        if let architect = payload.architect?.nilIfEmpty {
            rows.append(Row(label: "Architect", value: architect, mono: false))
        }

        let trailing: String? = payload.year.map { "\($0)" }

        return ModeContent(
            title: title,
            eyebrow: eyebrow,
            caption: payload.blurb(for: family),
            footer: payload.bestFooter,
            footerIcon: "location",
            footerExtra: payload.year.map { "\($0)" },
            cardTrailing: trailing,
            cardRowsPhoto: [],
            cardRowsArch: rows,
            mode: .architecture
        )
    }
}

// MARK: - Helpers

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension WidgetPayload {
    /// The big, front-and-center place name. Always a *place*: building,
    /// city, or region. Never a description of photo content.
    var bestTitle: String {
        if let n = buildingName?.nilIfEmpty { return n }
        if let first = locationComponents.first, !first.isEmpty { return first }
        if let c = locationCity?.nilIfEmpty { return c }
        if let area = area.nilIfEmpty { return area }
        if let country = locationCountry?.nilIfEmpty { return country }
        if let firstTag = tags?.first?.nilIfEmpty { return firstTag.capitalized }
        return "Wallpaper"
    }

    /// Short, categorical eyebrow — architect / style / country.
    var bestEyebrow: String? {
        if let architect = architect?.nilIfEmpty { return architect }
        if let style = style?.nilIfEmpty { return style }
        if let country = locationCountry?.nilIfEmpty, country != bestTitle { return country }
        return nil
    }

    /// Long-form caption (only in `.systemLarge`). Only the enrichment
    /// one-sentence — Unsplash descriptions are about photo content, not place.
    var bestCaption: String? { oneSentence?.nilIfEmpty }

    /// Pick the right-length blurb for a widget family. Falls back through
    /// shorter tiers when the longer ones are missing — e.g. an old payload
    /// that only has `oneSentence` still gets used at every size.
    func blurb(for family: WidgetFamily) -> String? {
        let short = (blurbShort ?? oneSentence)?.nilIfEmpty
        let medium = blurbMedium?.nilIfEmpty ?? short
        let long = blurbLong?.nilIfEmpty ?? medium
        switch family {
        case .systemSmall: return short
        case .systemMedium: return medium
        case .systemLarge: return long
        default: return medium
        }
    }

    /// Secondary location line. Only when it adds info beyond `bestTitle`.
    var bestFooter: String? {
        if locationComponents.count > 1 {
            let remainder = locationComponents.dropFirst().joined(separator: ", ")
            if !remainder.isEmpty, remainder != bestTitle { return remainder }
        }
        if let city = locationCity?.nilIfEmpty, let country = locationCountry?.nilIfEmpty, city != bestTitle {
            return "\(city), \(country)"
        }
        if let area = area.nilIfEmpty, area != bestTitle { return area }
        if let loc = locationName?.nilIfEmpty, loc != bestTitle { return loc }
        if let country = locationCountry?.nilIfEmpty, country != bestTitle { return country }
        return nil
    }

    private var locationComponents: [String] {
        guard let raw = locationName?.nilIfEmpty else { return [] }
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
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
        blurbShort: "A basilica in Barcelona, under construction since 1882.",
        blurbMedium: "Antoni Gaudí's Sagrada Família is a basilica in Barcelona's Eixample district, under construction since 1882. Its blend of Gothic and Catalan modernist forms is unlike anything before or since.",
        blurbLong: "Begun in 1882 to designs by Antoni Gaudí, the Sagrada Família is a Roman Catholic basilica that has been under continuous construction for over 140 years. The building fuses Gothic structural logic with Catalan modernist ornament, and Gaudí's later proposals departed even further into hyperboloid and parabolic geometries. Construction stalled during the Spanish Civil War when the original plaster models were destroyed, and modern crews have rebuilt the workflow from photographs and surviving fragments. Today it is one of Barcelona's most-visited landmarks, with completion targeted for the mid-2030s.",
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

#Preview("Photo · Medium · Architecture", as: .systemMedium) {
    PhotoWidget()
} timeline: {
    PaperEntry(date: .now, payload: .placeholder, mode: .architecture)
}

#Preview("Card · Medium · Photography", as: .systemMedium) {
    CardWidget()
} timeline: {
    PaperEntry(date: .now, payload: .placeholder, mode: .photography)
}

#Preview("Card · Large · Architecture", as: .systemLarge) {
    CardWidget()
} timeline: {
    PaperEntry(date: .now, payload: .placeholder, mode: .architecture)
}

#Preview("Clear · Medium · Photography", as: .systemMedium) {
    ClearWidget()
} timeline: {
    PaperEntry(date: .now, payload: .placeholder, mode: .photography)
}
