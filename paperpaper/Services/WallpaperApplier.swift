import Foundation
import SwiftData

@MainActor
final class WallpaperApplier {
    static let shared = WallpaperApplier()

    let cacheDir: URL

    init() {
        let fm = FileManager.default
        let support: URL
        do {
            support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        } catch {
            support = fm.temporaryDirectory
        }
        cacheDir = support.appending(path: "paperpaper/wallpapers")
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    func localFileURL(for unsplashID: String) -> URL {
        cacheDir.appending(path: "\(unsplashID).jpg")
    }

    @discardableResult
    func apply(unsplash: UnsplashPhoto) async throws -> Photo {
        let data = try await UnsplashService.shared.download(unsplash.urls.full)
        let fileURL = localFileURL(for: unsplash.id)
        try data.write(to: fileURL, options: .atomic)

        let photo = Store.shared.upsert(Photo(unsplash: unsplash))

        if photo.exif == nil, let extracted = ExifReader.read(from: data) {
            let exif = ExifRecord(extracted: extracted)
            exif.photo = photo
            Store.shared.context.insert(exif)
            try? Store.shared.context.save()
        }

        #if os(macOS)
        try WallpaperService.shared.setOnAllScreens(imageURL: fileURL)
        #endif

        Store.shared.recordShown(photo)
        return photo
    }

    @discardableResult
    func reapply(photo: Photo) async throws -> Bool {
        let fileURL = localFileURL(for: photo.unsplashID)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            guard let regularURL = photo.fullURL ?? photo.regularURL else { return false }
            let data = try await UnsplashService.shared.download(regularURL)
            try data.write(to: fileURL, options: .atomic)
        }
        #if os(macOS)
        try WallpaperService.shared.setOnAllScreens(imageURL: fileURL)
        #endif
        Store.shared.recordShown(photo)
        return true
    }
}
