import Foundation

struct WidgetPayload: Codable, Sendable {
    var unsplashID: String
    var imageFileName: String
    var buildingName: String?
    var oneSentence: String?
    /// Three length tiers from the architecture agent. Optional so an
    /// older payload (before this field existed) decodes cleanly.
    var blurbShort: String?
    var blurbMedium: String?
    var blurbLong: String?
    var area: String
    var authorName: String
    var authorProfileURLString: String?
    var cameraLine: String?
    var lensLine: String?
    var shotLine: String?
    var latitude: Double?
    var longitude: Double?
    var takenAtSeconds: Double?
    var updatedAtSeconds: Double
    // Raw Unsplash fields — always populated so the widget has *something*
    // useful to render before async enrichment completes (or when it fails).
    var photoDescription: String?
    var altDescription: String?
    var locationName: String?
    var locationCity: String?
    var locationCountry: String?
    var tags: [String]?
    var hexColor: String?

    static let appGroup = "group.me.ethanpan.paperpaper"
    static let defaultsKey = "widget.payload"

    static func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    static func widgetDir() -> URL {
        let fm = FileManager.default
        if let group = containerURL() {
            let dir = group.appending(path: "widget")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        let dir = support.appending(path: "paperpaper/widget")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func payloadFileURL() -> URL {
        widgetDir().appending(path: "payload.json")
    }

    func resolvedImageURL() -> URL? {
        guard !imageFileName.isEmpty else { return nil }
        return WidgetPayload.widgetDir().appending(path: imageFileName)
    }

    /// Primary: App-Group-scoped UserDefaults. This bypasses file xattr issues
    /// (com.apple.quarantine / com.apple.provenance) that can block a
    /// differently-sandboxed widget extension from reading a file written by a
    /// Debug-build main app. UserDefaults is the canonical macOS cross-process
    /// share path for WidgetKit. The file copy remains as a fallback.
    static func read() -> WidgetPayload? {
        if let defaults = UserDefaults(suiteName: appGroup),
           let data = defaults.data(forKey: defaultsKey),
           let payload = try? JSONDecoder().decode(WidgetPayload.self, from: data) {
            return payload
        }
        guard let data = try? Data(contentsOf: payloadFileURL()) else { return nil }
        return try? JSONDecoder().decode(WidgetPayload.self, from: data)
    }

    func write() throws {
        let data = try JSONEncoder().encode(self)
        if let defaults = UserDefaults(suiteName: Self.appGroup) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
        try data.write(to: Self.payloadFileURL(), options: .atomic)
    }
}

// MARK: - Display helpers
//
// The widget extension keeps its own copy of these helpers (they're private
// to that target). We mirror them here in the main-app target so views like
// MenuBarContent and NowView can display the same titles / footers without
// reaching into the widget bundle.

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
