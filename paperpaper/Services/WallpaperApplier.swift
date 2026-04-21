import Foundation
import SwiftData

@MainActor
final class WallpaperApplier {
    static let shared = WallpaperApplier()

    func localFileURL(for unsplashID: String) -> URL {
        ImageCache.shared.fileURL(for: unsplashID)
    }

    @discardableResult
    func apply(unsplash: UnsplashPhoto) async throws -> Photo {
        let fileURL = try await ensureDownloaded(id: unsplash.id, url: unsplash.urls.full)
        ImageCache.shared.touch(fileURL)

        let photo = Store.shared.upsert(Photo(unsplash: unsplash))

        if photo.exif == nil, let data = try? Data(contentsOf: fileURL), let extracted = ExifReader.read(from: data) {
            let exif = ExifRecord(extracted: extracted)
            exif.photo = photo
            Store.shared.context.insert(exif)
            try? Store.shared.context.save()
        }

        #if os(macOS)
        try WallpaperService.shared.setOnAllScreens(imageURL: fileURL)
        #endif

        Store.shared.recordShown(photo)

        enforceCacheCap()
        return photo
    }

    @discardableResult
    func reapply(photo: Photo) async throws -> Bool {
        guard let fullURL = photo.fullURL ?? photo.regularURL else { return false }
        let fileURL = try await ensureDownloaded(id: photo.unsplashID, url: fullURL)
        ImageCache.shared.touch(fileURL)

        #if os(macOS)
        try WallpaperService.shared.setOnAllScreens(imageURL: fileURL)
        #endif

        Store.shared.recordShown(photo)
        enforceCacheCap()
        return true
    }

    func preCache(_ unsplash: UnsplashPhoto) async {
        _ = try? await ensureDownloaded(id: unsplash.id, url: unsplash.urls.full)
    }

    private func ensureDownloaded(id: String, url: URL) async throws -> URL {
        let local = ImageCache.shared.fileURL(for: id)
        if FileManager.default.fileExists(atPath: local.path) {
            return local
        }
        let data = try await UnsplashService.shared.download(url)
        return try ImageCache.shared.put(data: data, for: id)
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
