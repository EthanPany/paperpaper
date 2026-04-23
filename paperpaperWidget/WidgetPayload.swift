import Foundation
import os

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
    private static let log = Logger(subsystem: "ep.paperpaper", category: "widget-sync")

    static func containerURL() -> URL? {
        let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        if url == nil {
            log.error("widget has NO access to App Group container — check widget entitlements")
        }
        return url
    }

    static func fileURL() -> URL? {
        containerURL()?.appending(path: "widget/payload.json")
    }

    func resolvedImageURL() -> URL? {
        guard !imageFileName.isEmpty, let container = WidgetPayload.containerURL() else { return nil }
        return container.appending(path: "widget/\(imageFileName)")
    }

    static func read() -> WidgetPayload? {
        guard let url = fileURL() else {
            log.error("widget read: no App Group URL")
            return nil
        }
        let exists = FileManager.default.fileExists(atPath: url.path)
        log.info("widget read: file=\(url.path, privacy: .public) exists=\(exists, privacy: .public)")
        guard exists, let data = try? Data(contentsOf: url) else {
            log.error("widget read: file unreadable at \(url.path, privacy: .public)")
            return nil
        }
        do {
            let payload = try JSONDecoder().decode(WidgetPayload.self, from: data)
            log.info("widget read: decoded id=\(payload.unsplashID, privacy: .public) image=\(payload.imageFileName, privacy: .public)")
            return payload
        } catch {
            log.error("widget read: decode failed \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
