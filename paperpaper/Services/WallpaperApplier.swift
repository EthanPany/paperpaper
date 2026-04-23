import Foundation
import SwiftData
import os
import Darwin
#if canImport(WidgetKit)
import WidgetKit
#endif

@MainActor
final class WallpaperApplier {
    static let shared = WallpaperApplier()

    private let log = Logger(subsystem: "ep.paperpaper", category: "widget-sync")

    func localFileURL(for unsplashID: String) -> URL {
        ImageCache.shared.fileURL(for: unsplashID)
    }

    @discardableResult
    func apply(unsplash: UnsplashPhoto) async throws -> Photo {
        let rawFile = try await ensureDownloaded(id: unsplash.id, url: unsplash.urls.full)
        ImageCache.shared.touch(rawFile)

        let photo = Store.shared.upsert(Photo(unsplash: unsplash))

        if photo.exif == nil, let data = try? Data(contentsOf: rawFile), let extracted = ExifReader.read(from: data) {
            let exif = ExifRecord(extracted: extracted)
            exif.photo = photo
            Store.shared.context.insert(exif)
            try? Store.shared.context.save()
        }

        let appliedFile = (try? composeOverlayIfEnabled(for: photo, sourceFile: rawFile)) ?? rawFile

        Store.shared.recordShown(photo)
        // Sync the widget first, so even if setting the wallpaper itself fails
        // (permission, disk, etc.) the widget still shows the just-picked photo.
        writeWidgetPayload(for: photo, file: appliedFile)

        #if os(macOS)
        try WallpaperService.shared.setOnAllScreens(imageURL: appliedFile)
        #endif

        enforceCacheCap()
        return photo
    }

    @discardableResult
    func reapply(photo: Photo) async throws -> Bool {
        guard let fullURL = photo.fullURL ?? photo.regularURL else { return false }
        let rawFile = try await ensureDownloaded(id: photo.unsplashID, url: fullURL)
        ImageCache.shared.touch(rawFile)

        let appliedFile = (try? composeOverlayIfEnabled(for: photo, sourceFile: rawFile)) ?? rawFile

        Store.shared.recordShown(photo)
        writeWidgetPayload(for: photo, file: appliedFile)

        #if os(macOS)
        try WallpaperService.shared.setOnAllScreens(imageURL: appliedFile)
        #endif

        enforceCacheCap()
        return true
    }

    func preCache(_ unsplash: UnsplashPhoto) async {
        _ = try? await ensureDownloaded(id: unsplash.id, url: unsplash.urls.full)
    }

    /// Writes the widget payload using the most recent applied photo, if any.
    /// Call at launch and from a manual "Refresh widget" control to repair sync.
    func syncWidgetFromCurrent() {
        let descriptor = FetchDescriptor<Photo>(sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)])
        guard let latest = try? Store.shared.context.fetch(descriptor).first(where: { $0.lastSeenAt != nil }) else {
            log.info("syncWidgetFromCurrent: no applied photo yet")
            return
        }
        let style = Store.shared.overlay()
        let raw = ImageCache.shared.fileURL(for: latest.unsplashID)
        let overlay = ImageCache.shared.dir.appending(path: "\(latest.unsplashID).overlay.jpg")
        let preferred: URL = {
            if style.enabled, FileManager.default.fileExists(atPath: overlay.path) { return overlay }
            return raw
        }()
        writeWidgetPayload(for: latest, file: preferred)
    }

    func enrichIfNeeded(_ photo: Photo) async {
        if let existing = photo.enrichment, existing.enrichedAt != nil { return }

        let candidate = BuildingDetector.detect(
            description: photo.photoDescription,
            altDescription: photo.altDescription,
            tags: photo.tags,
            locationName: photo.locationName ?? photo.areaText
        )

        let enrichment = photo.enrichment ?? {
            let e = Enrichment()
            e.photo = photo
            Store.shared.context.insert(e)
            return e
        }()

        guard let candidate else {
            enrichment.confidence = .areaOnly
            enrichment.enrichedAt = .now
            try? Store.shared.context.save()
            rewriteWidgetPayloadIfCurrent(photo)
            return
        }

        let gps: (Double, Double)?
        if let lat = photo.exif?.latitude, let lon = photo.exif?.longitude {
            gps = (lat, lon)
        } else {
            gps = nil
        }

        do {
            let result = try await OllamaService.shared.enrich(candidate: candidate, tags: photo.tags, gps: gps)
            enrichment.buildingName = result.name?.isEmpty == false ? result.name : candidate.name
            enrichment.architect = result.architect
            enrichment.year = result.year
            enrichment.style = result.style
            enrichment.oneSentence = result.one_sentence
            enrichment.confidence = .building
            enrichment.enrichedAt = .now
            enrichment.modelUsed = UserDefaults.standard.string(forKey: "ollama.model")
        } catch {
            enrichment.buildingName = candidate.name
            enrichment.confidence = .areaOnly
            enrichment.enrichedAt = .now
        }
        try? Store.shared.context.save()
        rewriteWidgetPayloadIfCurrent(photo)
    }

    // MARK: - Private helpers

    private func ensureDownloaded(id: String, url: URL) async throws -> URL {
        let local = ImageCache.shared.fileURL(for: id)
        if FileManager.default.fileExists(atPath: local.path) { return local }
        let data = try await UnsplashService.shared.download(url)
        return try ImageCache.shared.put(data: data, for: id)
    }

    private func composeOverlayIfEnabled(for photo: Photo, sourceFile: URL) throws -> URL {
        let style = Store.shared.overlay()
        guard style.enabled else { return sourceFile }

        #if os(macOS)
        let output = ImageCache.shared.dir.appending(path: "\(photo.unsplashID).overlay.jpg")
        let text = OverlayRenderer.text(for: photo, style: style)
        try OverlayRenderer.compose(imageURL: sourceFile, text: text, style: style, to: output)
        return output
        #else
        return sourceFile
        #endif
    }

    /// macOS tags files written by Debug builds run from DerivedData with
    /// `com.apple.quarantine` and `com.apple.provenance` xattrs. The widget
    /// extension (different sandbox) then can't read those files. We strip both
    /// on every App Group write and log the POSIX error if the call fails so
    /// we can see what's actually happening.
    private func stripXattrsForWidget(_ url: URL) {
        let path = url.path
        for name in ["com.apple.quarantine", "com.apple.provenance"] {
            let result = path.withCString { cpath in
                name.withCString { cname in
                    removexattr(cpath, cname, 0)
                }
            }
            if result != 0 {
                let err = errno
                // ENOATTR = 93 means the attr just wasn't there → ignore quietly
                if err != 93 {
                    log.error("removexattr \(name, privacy: .public) on \(path, privacy: .public) failed errno=\(err, privacy: .public)")
                }
            }
        }
    }

    private func writeWidgetPayload(for photo: Photo, file: URL) {
        let imageFileName = copyImageToAppGroup(from: file, photoID: photo.unsplashID)

        let payload = WidgetPayload(
            unsplashID: photo.unsplashID,
            imageFileName: imageFileName,
            buildingName: photo.enrichment?.buildingName,
            architect: photo.enrichment?.architect,
            year: photo.enrichment?.year,
            style: photo.enrichment?.style,
            oneSentence: photo.enrichment?.oneSentence,
            area: photo.areaText,
            authorName: photo.authorName,
            authorProfileURLString: photo.authorProfileURLString,
            cameraLine: photo.exif?.cameraLine.isEmpty == false ? photo.exif?.cameraLine : nil,
            lensLine: photo.exif?.lensLine.isEmpty == false ? photo.exif?.lensLine : nil,
            shotLine: photo.exif?.shotLine.isEmpty == false ? photo.exif?.shotLine : nil,
            latitude: photo.exif?.latitude,
            longitude: photo.exif?.longitude,
            takenAtSeconds: photo.exif?.takenAt?.timeIntervalSince1970,
            updatedAtSeconds: Date.now.timeIntervalSince1970
        )
        do {
            try payload.write()
            stripXattrsForWidget(WidgetPayload.payloadFileURL())
            log.info("wrote widget payload for \(photo.unsplashID, privacy: .public) image=\(imageFileName, privacy: .public)")
        } catch {
            log.error("payload.write failed: \(error.localizedDescription, privacy: .public)")
        }

        #if canImport(WidgetKit)
        // Reload everything in the widget bundle. WidgetKit throttles internally
        // but this is still the correct way to tell the widget host "something new".
        WidgetCenter.shared.reloadAllTimelines()
        WidgetCenter.shared.invalidateConfigurationRecommendations()
        #endif
    }

    private func copyImageToAppGroup(from sourceFile: URL, photoID: String) -> String {
        let fm = FileManager.default
        let dir = WidgetPayload.widgetDir()
        let name = "current.jpg"
        let destination = dir.appending(path: name)
        if !fm.fileExists(atPath: sourceFile.path) {
            log.error("copy source missing: \(sourceFile.path, privacy: .public)")
            return ""
        }
        _ = try? fm.removeItem(at: destination)
        do {
            try fm.copyItem(at: sourceFile, to: destination)
            stripXattrsForWidget(destination)
            return name
        } catch {
            log.error("copy to app group failed: \(error.localizedDescription, privacy: .public) dest=\(destination.path, privacy: .public)")
            return ""
        }
    }

    private func rewriteWidgetPayloadIfCurrent(_ photo: Photo) {
        let descriptor = FetchDescriptor<Photo>(sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)])
        guard let latest = try? Store.shared.context.fetch(descriptor).first(where: { $0.lastSeenAt != nil }),
              latest.unsplashID == photo.unsplashID else { return }

        let style = Store.shared.overlay()
        let raw = ImageCache.shared.fileURL(for: photo.unsplashID)
        let overlay = ImageCache.shared.dir.appending(path: "\(photo.unsplashID).overlay.jpg")
        let preferred: URL = {
            if style.enabled, FileManager.default.fileExists(atPath: overlay.path) { return overlay }
            return raw
        }()
        writeWidgetPayload(for: photo, file: preferred)
    }

    private func enforceCacheCap() {
        let maxMB = UserDefaults.standard.object(forKey: "cache.maxSizeMB") as? Double ?? 500
        let maxBytes = Int64(maxMB * 1024 * 1024)
        let protected = currentWallpaperIDs()
        ImageCache.shared.enforceCap(maxBytes: maxBytes, protectedIDs: protected)
    }

    private func currentWallpaperIDs() -> Set<String> {
        let descriptor = FetchDescriptor<Photo>(sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)])
        guard let recent = try? Store.shared.context.fetch(descriptor).prefix(3) else { return [] }
        return Set(recent.map(\.unsplashID))
    }
}
