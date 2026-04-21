import SwiftUI
import SwiftData

struct OverlayView: View {
    @Query private var styles: [OverlayStyle]
    @Query(sort: \Photo.lastSeenAt, order: .reverse) private var recent: [Photo]

    private var style: OverlayStyle { styles.first ?? Store.shared.overlay() }
    private var previewPhoto: Photo? { recent.first(where: { $0.lastSeenAt != nil }) ?? recent.first }

    var body: some View {
        HStack(spacing: 0) {
            Form {
                Section("Text") {
                    Toggle("Burn in text on wallpaper", isOn: Binding(
                        get: { style.enabled },
                        set: { style.enabled = $0; save() }
                    ))
                    Picker("Content", selection: Binding(
                        get: { style.content },
                        set: { style.content = $0; save() }
                    )) {
                        Text("Name + architect").tag(OverlayContent.nameAndArchitect)
                        Text("One-sentence blurb").tag(OverlayContent.blurb)
                        Text("EXIF one line").tag(OverlayContent.exifOneLine)
                        Text("Photographer + area").tag(OverlayContent.photographerAndArea)
                    }
                    Picker("Corner", selection: Binding(
                        get: { style.corner },
                        set: { style.corner = $0; save() }
                    )) {
                        Text("Top left").tag(OverlayCorner.topLeft)
                        Text("Top right").tag(OverlayCorner.topRight)
                        Text("Bottom left").tag(OverlayCorner.bottomLeft)
                        Text("Bottom right").tag(OverlayCorner.bottomRight)
                    }
                    HStack {
                        Text("Margin")
                        Slider(value: Binding(
                            get: { style.marginPoints },
                            set: { style.marginPoints = $0; save() }
                        ), in: 0...200)
                        Text("\(Int(style.marginPoints)) px")
                            .monospacedDigit()
                            .frame(width: 70, alignment: .trailing)
                    }
                    HStack {
                        Text("Size")
                        Slider(value: Binding(
                            get: { style.fontSize },
                            set: { style.fontSize = $0; save() }
                        ), in: 8...96)
                        Text("\(Int(style.fontSize)) pt")
                            .monospacedDigit()
                            .frame(width: 70, alignment: .trailing)
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

            OverlayPreview(photo: previewPhoto, style: style)
                .padding()
        }
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
                        default: Color.gray.opacity(0.2)
                        }
                    }
                } else {
                    Color.gray.opacity(0.2)
                }

                if style.enabled {
                    overlayText
                        .padding(style.marginPoints)
                        .frame(maxWidth: geo.size.width, maxHeight: geo.size.height, alignment: alignment)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var overlayText: some View {
        let text = photo.map { OverlayRenderer.text(for: $0, style: style) } ?? "Preview text"
        let display = text.isEmpty ? "Preview text" : text
        return Text(display)
            .font(.system(size: style.fontSize))
            .foregroundStyle(color)
            .shadow(color: .black.opacity(style.dropShadow ? 0.7 : 0), radius: style.dropShadow ? 6 : 0, x: 0, y: style.dropShadow ? -2 : 0)
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
