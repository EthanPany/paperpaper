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

    func enforceCap(maxBytes: Int64, protectedIDs: Set<String> = []) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }

        let sized = items.compactMap { url -> (URL, Int64, Date)? in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            let date = values?.contentModificationDate ?? .distantPast
            return (url, size, date)
        }

        var total = sized.reduce(0) { $0 + $1.1 }
        guard total > maxBytes else { return }

        let sortedByOldest = sized.sorted { $0.2 < $1.2 }

        for (url, size, _) in sortedByOldest {
            if total <= maxBytes { break }
            let id = url.deletingPathExtension().lastPathComponent
            if protectedIDs.contains(id) { continue }
            try? fm.removeItem(at: url)
            total -= size
        }
    }

    func clear() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for item in items {
            try? fm.removeItem(at: item)
        }
    }
}
