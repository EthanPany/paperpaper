import Foundation

struct WidgetPayload: Codable, Sendable {
    var unsplashID: String
    var imageFileName: String
    var buildingName: String?
    var architect: String?
    var year: Int?
    var style: String?
    var oneSentence: String?
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

    static let appGroup = "group.ep.paperpaper"
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
