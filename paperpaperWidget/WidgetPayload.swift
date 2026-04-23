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
        // Leave a breadcrumb so the main app can prove the widget process is alive.
        writeBreadcrumb(stage: "read-entered")

        guard let url = fileURL() else {
            log.error("widget read: no App Group URL")
            writeBreadcrumb(stage: "no-container")
            return nil
        }
        let exists = FileManager.default.fileExists(atPath: url.path)
        log.info("widget read: file=\(url.path, privacy: .public) exists=\(exists, privacy: .public)")
        guard exists, let data = try? Data(contentsOf: url) else {
            log.error("widget read: file unreadable at \(url.path, privacy: .public)")
            writeBreadcrumb(stage: "file-missing")
            return nil
        }
        do {
            let payload = try JSONDecoder().decode(WidgetPayload.self, from: data)
            log.info("widget read: decoded id=\(payload.unsplashID, privacy: .public) image=\(payload.imageFileName, privacy: .public)")
            writeBreadcrumb(stage: "ok:\(payload.unsplashID)")
            return payload
        } catch {
            log.error("widget read: decode failed \(error.localizedDescription, privacy: .public)")
            writeBreadcrumb(stage: "decode-failed")
            return nil
        }
    }

    private static func writeBreadcrumb(stage: String) {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return }
        let dir = container.appending(path: "widget")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "last_read.json")
        let payload: [String: Any] = [
            "readAt": Date.now.timeIntervalSince1970,
            "stage": stage,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
