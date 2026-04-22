import WidgetKit
import AppIntents

enum WidgetLayoutChoice: String, AppEnum {
    case blurb
    case exif
    case minimal
    case photographer

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Layout"
    }

    static var caseDisplayRepresentations: [WidgetLayoutChoice: DisplayRepresentation] = [
        .blurb: "Blurb (name, architect, one-sentence)",
        .exif: "EXIF (camera, lens, aperture, ISO)",
        .minimal: "Minimal (name only)",
        .photographer: "Photographer (author, area, license)",
    ]
}

struct ConfigurationAppIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "paperpaper Widget" }
    static var description: IntentDescription { "Show the current wallpaper's metadata." }

    @Parameter(title: "Layout", default: .blurb)
    var layout: WidgetLayoutChoice
}
