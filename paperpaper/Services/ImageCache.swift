import Foundation

@MainActor
final class ImageCache {
    static let shared = ImageCache()

    let dir: URL

    init() {
        let fm = FileManager.default
        let support: URL
        do {
            support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        } catch {
            support = fm.temporaryDirectory
        }
        dir = support.appending(path: "paperpaper/wallpapers")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func fileURL(for id: String) -> URL {
        dir.appending(path: "\(id).jpg")
    }

    func exists(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: id).path)
    }

    @discardableResult
    func put(data: Data, for id: String) throws -> URL {
        let url = fileURL(for: id)
        try data.write(to: url, options: .atomic)
        touch(url)
        return url
    }

    func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: url.path)
    }

    func currentSizeBytes() -> Int64 {
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for item in items {
            if let size = try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    func currentCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).count) ?? 0
    }

    /// IDs of the `limit` most-recently-modified cached image files. Used to
    /// protect a freshly prefetched warm pool from immediate eviction: those
    /// files have the newest mtimes (just downloaded) but no `lastSeenAt` yet,
    /// so they aren't in the "recently shown" protected set. Without this they'd
    /// be dropped the instant they land whenever the cap is 0 ("keep only
    /// references"), silently defeating prefetch.
    func recentlyCachedIDs(limit: Int) -> Set<String> {
        guard limit > 0 else { return [] }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let dated = items.map { url -> (String, Date) in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (url.deletingPathExtension().lastPathComponent, date)
        }
        return Set(dated.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0))
    }

    /// Keep at most `maxCount` image files on disk — the newest by
    /// modification date — evicting the older remainder. A file whose id is in
    /// `protectedIDs` (the current / recent wallpapers, any prefetch) is never
    /// removed even if it falls outside the newest set, so the showing
    /// wallpaper can't be evicted out from under itself. Only image bytes are
    /// removed — the caller's SwiftData Photo/Enrichment rows are untouched, so
    /// a re-encountered photo is simply re-downloaded and never re-enriched.
    /// Returns the number of files removed.
    @discardableResult
    func enforceCount(maxCount: Int, protectedIDs: Set<String> = []) -> Int {
        let fm = FileManager.default
        guard maxCount >= 0,
              let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey]
              )
        else { return 0 }

        guard items.count > maxCount else { return 0 }

        let dated = items.map { url -> (URL, String, Date) in
            let id = url.deletingPathExtension().lastPathComponent
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (url, id, date)
        }
        // Keep the newest `maxCount`; from the older remainder evict anything
        // not protected.
        let sortedNewestFirst = dated.sorted { $0.2 > $1.2 }
        var removed = 0
        for (url, id, _) in sortedNewestFirst.dropFirst(maxCount) {
            if protectedIDs.contains(id) { continue }
            try? fm.removeItem(at: url)
            removed += 1
        }
        return removed
    }

    func clear() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for item in items {
            try? fm.removeItem(at: item)
        }
    }
}
