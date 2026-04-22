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

    static func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    static func payloadFileURL() -> URL? {
        containerURL()?.appending(path: "widget/payload.json")
    }

    func resolvedImageURL() -> URL? {
        guard !imageFileName.isEmpty, let container = WidgetPayload.containerURL() else { return nil }
        return container.appending(path: "widget/\(imageFileName)")
    }

    static func read() -> WidgetPayload? {
        guard let url = payloadFileURL(), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetPayload.self, from: data)
    }
}
