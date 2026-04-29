import Foundation
import os

struct WidgetPayload: Codable, Sendable {
    var unsplashID: String
    var imageFileName: String
    var buildingName: String?
    var oneSentence: String?
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
    var photoDescription: String?
    var altDescription: String?
    var locationName: String?
    var locationCity: String?
    var locationCountry: String?
    var tags: [String]?
    var hexColor: String?

    static let appGroup = "group.ep.paperpaper"
    static let defaultsKey = "widget.payload"
    private static let log = Logger(subsystem: "ep.paperpaper", category: "widget-sync")
    private static let breadcrumbName = "last_read.json"

    static func containerURL() -> URL? {
        let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        if url == nil {
            log.error("widget has NO access to App Group container — check widget entitlements")
        }
        return url
    }

    private static func writeBreadcrumb(stage: String, detail: String? = nil) {
        guard let container = containerURL() else { return }
        let dir = container.appending(path: "widget")
        let url = dir.appending(path: breadcrumbName)
        let payload: [String: Any] = [
            "readAt": Date.now.timeIntervalSince1970,
            "stage": stage,
            "detail": detail ?? "",
        ]
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("widget breadcrumb write failed: \(error.localizedDescription, privacy: .public)")
        }
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
                    writeBreadcrumb(stage: "defaults-hit", detail: payload.unsplashID)
                    log.info("widget read: defaults hit id=\(payload.unsplashID, privacy: .public) image=\(payload.imageFileName, privacy: .public)")
                    return payload
                } catch {
                    writeBreadcrumb(stage: "defaults-decode-failed", detail: error.localizedDescription)
                    log.error("widget read: defaults decode failed \(error.localizedDescription, privacy: .public)")
                }
            } else {
                writeBreadcrumb(stage: "defaults-empty")
                log.info("widget read: defaults had no data for key \(defaultsKey, privacy: .public)")
            }
        } else {
            writeBreadcrumb(stage: "defaults-unavailable")
            log.error("widget read: UserDefaults(suiteName: \(appGroup, privacy: .public)) returned nil")
        }

        // Fallback: read the file
        guard let container = containerURL() else {
            writeBreadcrumb(stage: "container-unavailable")
            return nil
        }
        let fileURL = container.appending(path: "widget/payload.json")
        let exists = FileManager.default.fileExists(atPath: fileURL.path)
        if !exists {
            writeBreadcrumb(stage: "file-missing", detail: fileURL.lastPathComponent)
        }
        log.info("widget read: fallback file=\(fileURL.path, privacy: .public) exists=\(exists, privacy: .public)")
        guard exists else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            let payload = try JSONDecoder().decode(WidgetPayload.self, from: data)
            writeBreadcrumb(stage: "file-hit", detail: payload.unsplashID)
            log.info("widget read: file hit id=\(payload.unsplashID, privacy: .public)")
            return payload
        } catch {
            writeBreadcrumb(stage: "file-read-failed", detail: error.localizedDescription)
            log.error("widget read: file error \(error.localizedDescription, privacy: .public) nsError=\((error as NSError).code, privacy: .public)")
            return nil
        }
    }
}
