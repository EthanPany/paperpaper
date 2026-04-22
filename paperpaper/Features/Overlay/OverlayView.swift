import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

struct OverlayView: View {
    @Query private var styles: [OverlayStyle]
    @Query(sort: \Photo.lastSeenAt, order: .reverse) private var recent: [Photo]

    private var style: OverlayStyle { styles.first ?? Store.shared.overlay() }
    private var previewPhoto: Photo? { recent.first(where: { $0.lastSeenAt != nil }) ?? recent.first }

    var body: some View {
        HStack(spacing: 0) {
            Form {
                Section("Burn in text") {
                    Toggle("Burn overlay into applied wallpaper", isOn: Binding(
                        get: { style.enabled },
                        set: { style.enabled = $0; save() }
                    ))
                    Text(style.enabled
                         ? "On: a composited JPEG replaces the original when set as wallpaper."
                         : "Off: the preview still shows you where the overlay would land, but the original image is applied.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Content") {
                    Picker("Text", selection: Binding(
                        get: { style.content },
                        set: { style.content = $0; save() }
                    )) {
                        Text("Name + architect").tag(OverlayContent.nameAndArchitect)
                        Text("One-sentence blurb").tag(OverlayContent.blurb)
                        Text("EXIF one line").tag(OverlayContent.exifOneLine)
                        Text("Photographer + area").tag(OverlayContent.photographerAndArea)
                    }
                }

                Section("Layout") {
                    Picker("Corner", selection: Binding(
                        get: { style.corner },
                        set: { style.corner = $0; save() }
                    )) {
                        Text("Top left").tag(OverlayCorner.topLeft)
                        Text("Top right").tag(OverlayCorner.topRight)
                        Text("Bottom left").tag(OverlayCorner.bottomLeft)
                        Text("Bottom right").tag(OverlayCorner.bottomRight)
                    }
                    Stepper(value: Binding(
                        get: { Int(style.marginPoints) },
                        set: { style.marginPoints = Double($0); save() }
                    ), in: 0...200, step: 4) {
                        HStack {
                            Text("Margin")
                            Spacer()
                            Text("\(Int(style.marginPoints)) px")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    Stepper(value: Binding(
                        get: { Int(style.fontSize) },
                        set: { style.fontSize = Double($0); save() }
                    ), in: 8...96) {
                        HStack {
                            Text("Size")
                            Spacer()
                            Text("\(Int(style.fontSize)) pt")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    TextField("Hex color (e.g. #FFFFFFEE)", text: Binding(
                        get: { style.hexColor },
                        set: { style.hexColor = $0; save() }
                    ))
                    Toggle("Drop shadow", isOn: Binding(
                        get: { style.dropShadow },
                        set: { style.dropShadow = $0; save() }
                    ))
                }
            }
            .formStyle(.grouped)
            .frame(width: 360)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(previewLabel)
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                OverlayPreview(photo: previewPhoto, style: style)
                    .aspectRatio(screenAspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(16)
        }
    }

    private var previewLabel: String {
        #if os(macOS)
        if let screen = NSScreen.main {
            let w = Int(screen.frame.width)
            let h = Int(screen.frame.height)
            return "Preview · \(w) × \(h)"
        }
        #endif
        return "Preview"
    }

    private var screenAspectRatio: CGFloat {
        #if os(macOS)
        if let screen = NSScreen.main {
            return screen.frame.width / max(screen.frame.height, 1)
        }
        #endif
        return 16.0 / 10.0
    }

    private func save() {
        try? Store.shared.context.save()
    }
}

private struct OverlayPreview: View {
    let photo: Photo?
    let style: OverlayStyle

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let url = photo?.regularURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFill()
                        default: PlaceholderGradient()
                        }
                    }
                } else {
                    PlaceholderGradient()
                }

                overlayText(geo: geo)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.quaternary, lineWidth: 1)
            )
        }
    }

    private func overlayText(geo: GeometryProxy) -> some View {
        let text = photo.map { OverlayRenderer.text(for: $0, style: style) } ?? "Preview text"
        let display = text.isEmpty ? "Preview text" : text

        // Scale the font/margin the same way the screen -> preview size scales.
        // previewScale = previewWidth / actualScreenWidth.
        #if os(macOS)
        let screenWidth = NSScreen.main?.frame.width ?? 1920
        #else
        let screenWidth: CGFloat = 1920
        #endif
        let scale = geo.size.width / screenWidth
        let previewFontSize = max(6, style.fontSize * scale)
        let previewMargin = max(2, style.marginPoints * scale)

        return Text(display)
            .font(.system(size: previewFontSize))
            .foregroundStyle(color.opacity(style.enabled ? 1 : 0.55))
            .shadow(color: .black.opacity(style.dropShadow ? 0.7 : 0), radius: style.dropShadow ? 6 : 0, x: 0, y: style.dropShadow ? -1 : 0)
            .padding(previewMargin)
            .frame(width: geo.size.width, height: geo.size.height, alignment: alignment)
    }

    private var alignment: Alignment {
        switch style.corner {
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }

    private var color: Color {
        Color(hex: style.hexColor) ?? .white
    }
}

private extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8 else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&value) else { return nil }
        let r, g, b, a: Double
        if s.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        } else {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

#Preview {
    OverlayView()
        .modelContainer(Store.shared.container)
        .frame(width: 900, height: 600)
}
