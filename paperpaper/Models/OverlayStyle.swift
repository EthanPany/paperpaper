import Foundation
import SwiftData

@Model
final class OverlayStyle {
    var enabled: Bool = false
    var cornerRaw: String = OverlayCorner.bottomRight.rawValue
    var contentRaw: String = OverlayContent.nameAndArchitect.rawValue
    var marginPoints: Double = 48
    var fontName: String = "SF Pro"
    var fontSize: Double = 18
    var hexColor: String = "#FFFFFFEE"
    var dropShadow: Bool = true

    init(
        enabled: Bool = false,
        corner: OverlayCorner = .bottomRight,
        content: OverlayContent = .nameAndArchitect,
        marginPoints: Double = 48,
        fontName: String = "SF Pro",
        fontSize: Double = 18,
        hexColor: String = "#FFFFFFEE",
        dropShadow: Bool = true
    ) {
        self.enabled = enabled
        self.cornerRaw = corner.rawValue
        self.contentRaw = content.rawValue
        self.marginPoints = marginPoints
        self.fontName = fontName
        self.fontSize = fontSize
        self.hexColor = hexColor
        self.dropShadow = dropShadow
    }

    var corner: OverlayCorner {
        get { OverlayCorner(rawValue: cornerRaw) ?? .bottomRight }
        set { cornerRaw = newValue.rawValue }
    }

    var content: OverlayContent {
        get { OverlayContent(rawValue: contentRaw) ?? .nameAndArchitect }
        set { contentRaw = newValue.rawValue }
    }
}
