import Foundation
#if os(macOS)
import AppKit
#endif

enum OverlayRenderError: Error, LocalizedError {
    case cannotLoad
    case cannotEncode

    var errorDescription: String? {
        switch self {
        case .cannotLoad: return "Could not load the source image."
        case .cannotEncode: return "Could not encode the composed image."
        }
    }
}

enum OverlayRenderer {
    static func text(for photo: Photo, style: OverlayStyle) -> String {
        switch style.content {
        case .nameAndArchitect:
            let parts = [photo.enrichment?.buildingName, photo.enrichment?.architect].compactMap { $0?.isEmpty == false ? $0 : nil }
            return parts.joined(separator: " · ")
        case .blurb:
            return photo.enrichment?.oneSentence ?? photo.enrichment?.buildingName ?? ""
        case .exifOneLine:
            guard let exif = photo.exif else { return "" }
            return [exif.cameraLine, exif.lensLine, exif.shotLine].filter { !$0.isEmpty }.joined(separator: " · ")
        case .photographerAndArea:
            let name = photo.authorName
            let area = photo.areaText
            return area.isEmpty ? name : "\(name) · \(area)"
        }
    }

    #if os(macOS)
    static func compose(imageURL: URL, text: String, style: OverlayStyle, to output: URL) throws {
        guard let nsImage = NSImage(contentsOf: imageURL) else { throw OverlayRenderError.cannotLoad }

        let size = nsImage.size
        guard size.width > 1, size.height > 1 else { throw OverlayRenderError.cannotLoad }

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        ) else {
            throw OverlayRenderError.cannotEncode
        }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        nsImage.draw(in: NSRect(origin: .zero, size: size))

        if !text.isEmpty {
            let font = NSFont(name: style.fontName, size: style.fontSize) ?? .systemFont(ofSize: style.fontSize)
            let color = NSColor(hex: style.hexColor) ?? .white
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
            ]
            if style.dropShadow {
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
                shadow.shadowOffset = NSSize(width: 0, height: -2)
                shadow.shadowBlurRadius = 6
                attrs[.shadow] = shadow
            }
            let attributed = NSAttributedString(string: text, attributes: attrs)
            let textSize = attributed.size()
            let margin = CGFloat(style.marginPoints)
            let origin: CGPoint
            switch style.corner {
            case .topLeft:     origin = CGPoint(x: margin, y: size.height - textSize.height - margin)
            case .topRight:    origin = CGPoint(x: size.width - textSize.width - margin, y: size.height - textSize.height - margin)
            case .bottomLeft:  origin = CGPoint(x: margin, y: margin)
            case .bottomRight: origin = CGPoint(x: size.width - textSize.width - margin, y: margin)
            }
            attributed.draw(at: origin)
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else {
            throw OverlayRenderError.cannotEncode
        }
        try data.write(to: output, options: .atomic)
    }
    #endif
}

#if os(macOS)
private extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8 else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&value) else { return nil }
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255
        } else {
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
#endif
