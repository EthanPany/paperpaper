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
    static let defaultsKey = "widget.payload"
    private static let log = Logger(subsystem: "ep.paperpaper", category: "widget-sync")

    static func containerURL() -> URL? {
        let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        if url == nil {
            log.error("widget has NO access to App Group container — check widget entitlements")
        }
        return url
    }

    func resolvedImageURL() -> URL? {
        guard !imageFileName.isEmpty, let container = WidgetPayload.containerURL() else { return nil }
        return container.appending(path: "widget/\(imageFileName)")
    }

    /// Try App-Group UserDefaults first (no xattr blockers), then fall back to
    /// the JSON file inside the App Group container. On every failure path we
    /// log the actual Swift error so we can see the specific POSIX reason.
    static func read() -> WidgetPayload? {
        if let defaults = UserDefaults(suiteName: appGroup) {
            if let data = defaults.data(forKey: defaultsKey) {
                do {
                    let payload = try JSONDecoder().decode(WidgetPayload.self, from: data)
                    log.info("widget read: defaults hit id=\(payload.unsplashID, privacy: .public) image=\(payload.imageFileName, privacy: .public)")
                    return payload
                } catch {
                    log.error("widget read: defaults decode failed \(error.localizedDescription, privacy: .public)")
                }
            } else {
                log.info("widget read: defaults had no data for key \(defaultsKey, privacy: .public)")
            }
        } else {
            log.error("widget read: UserDefaults(suiteName: \(appGroup, privacy: .public)) returned nil")
        }

        // Fallback: read the file
        guard let container = containerURL() else { return nil }
        let fileURL = container.appending(path: "widget/payload.json")
        let exists = FileManager.default.fileExists(atPath: fileURL.path)
        log.info("widget read: fallback file=\(fileURL.path, privacy: .public) exists=\(exists, privacy: .public)")
        guard exists else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            let payload = try JSONDecoder().decode(WidgetPayload.self, from: data)
            log.info("widget read: file hit id=\(payload.unsplashID, privacy: .public)")
            return payload
        } catch {
            log.error("widget read: file error \(error.localizedDescription, privacy: .public) nsError=\((error as NSError).code, privacy: .public)")
            return nil
        }
    }
}
