import Foundation

struct WidgetPayload: Codable, Sendable {
    var unsplashID: String
    var imageFilePath: String
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

    static func fileURL() -> URL {
        let fm = FileManager.default
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            let dir = group.appending(path: "widget")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appending(path: "payload.json")
        }
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        let dir = support.appending(path: "paperpaper/widget")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "payload.json")
    }

    static func read() -> WidgetPayload? {
        guard let data = try? Data(contentsOf: fileURL()) else { return nil }
        return try? JSONDecoder().decode(WidgetPayload.self, from: data)
    }

    func write() throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: Self.fileURL(), options: .atomic)
    }
}
