import Foundation
import SwiftData

@MainActor
final class Store {
    static let shared = Store()

    let container: ModelContainer

    private init() {
        let schema = Schema([
            Photo.self,
            ExifRecord.self,
            Enrichment.self,
            HistoryEvent.self,
            RotationRule.self,
            FilterPrefs.self,
            OverlayStyle.self,
            SyncPrefs.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        ensureSingletonsExist()
    }

    var context: ModelContext { container.mainContext }

    func rule() -> RotationRule {
        first(RotationRule.self) ?? insert(RotationRule())
    }

    func filters() -> FilterPrefs {
        first(FilterPrefs.self) ?? insert(FilterPrefs())
    }

    func overlay() -> OverlayStyle {
        first(OverlayStyle.self) ?? insert(OverlayStyle())
    }

    func syncPrefs() -> SyncPrefs {
        first(SyncPrefs.self) ?? insert(SyncPrefs())
    }

    func photo(withUnsplashID id: String) -> Photo? {
        let descriptor = FetchDescriptor<Photo>(predicate: #Predicate { $0.unsplashID == id })
        return try? context.fetch(descriptor).first
    }

    @discardableResult
    func upsert(_ photo: Photo) -> Photo {
        if let existing = self.photo(withUnsplashID: photo.unsplashID) {
            return existing
        }
        context.insert(photo)
        try? context.save()
        return photo
    }

    func recordShown(_ photo: Photo, displayID: String? = nil, spaceTag: String? = nil) {
        let event = HistoryEvent(setAt: .now, displayID: displayID, spaceTag: spaceTag)
        event.photo = photo
        context.insert(event)
        photo.lastSeenAt = event.setAt
        try? context.save()
    }

    func toggleFavorite(_ photo: Photo) {
        photo.favoritedAt = photo.favoritedAt == nil ? .now : nil
        try? context.save()
    }

    func hide(_ photo: Photo) {
        photo.hiddenAt = .now
        try? context.save()
    }

    func seedFakeData(count: Int = 12) {
        let descriptor = FetchDescriptor<Photo>()
        let existing = (try? context.fetchCount(descriptor)) ?? 0
        guard existing == 0 else { return }

        let samples: [SeedSample] = [
            SeedSample(title: "Sagrada Família façade", city: "Barcelona", country: "Spain", tags: ["architecture", "gothic", "gaudi", "Sagrada Familia"]),
            SeedSample(title: "Guggenheim curves", city: "Bilbao", country: "Spain", tags: ["architecture", "museum", "Guggenheim", "Gehry"]),
            SeedSample(title: "Farnsworth House", city: "Plano", country: "United States", tags: ["architecture", "modernism", "Mies", "Farnsworth"]),
            SeedSample(title: "Pantheon dome", city: "Rome", country: "Italy", tags: ["architecture", "classical", "dome", "Pantheon"]),
            SeedSample(title: "Ronchamp chapel", city: "Ronchamp", country: "France", tags: ["architecture", "Corbusier", "chapel", "Ronchamp"]),
            SeedSample(title: "Zaha's Heydar Aliyev Center", city: "Baku", country: "Azerbaijan", tags: ["architecture", "Hadid", "Heydar Aliyev"]),
            SeedSample(title: "Manhattan skyline", city: "New York", country: "United States", tags: ["architecture", "skyline", "skyscraper"]),
            SeedSample(title: "Concrete brutalism", city: "London", country: "United Kingdom", tags: ["architecture", "brutalism", "Barbican"]),
            SeedSample(title: "Terraced houses", city: "Porto", country: "Portugal", tags: ["architecture", "terrace", "tiles"]),
            SeedSample(title: "Kyoto temple eaves", city: "Kyoto", country: "Japan", tags: ["architecture", "temple", "Kyoto"]),
            SeedSample(title: "Tokyo neon midrise", city: "Tokyo", country: "Japan", tags: ["architecture", "urban", "night"]),
            SeedSample(title: "Alhambra courtyard", city: "Granada", country: "Spain", tags: ["architecture", "moorish", "Alhambra"]),
        ]

        for (i, s) in samples.prefix(count).enumerated() {
            let url = URL(string: "https://placehold.co/1600x1000?text=\(s.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "photo")")!
            let photo = Photo(
                unsplashID: "seed-\(i)",
                thumbURL: url,
                regularURL: url,
                fullURL: url,
                authorName: "Seed Photographer \(i + 1)",
                photoDescription: s.title,
                tags: s.tags,
                locationCity: s.city,
                locationCountry: s.country,
                width: 1600,
                height: 1000,
                hexColor: "#888888",
                firstSeenAt: .now.addingTimeInterval(-Double(i) * 3600)
            )
            context.insert(photo)
        }
        try? context.save()
    }

    func deleteAllLocalData() {
        for type in [Photo.self, ExifRecord.self, Enrichment.self, HistoryEvent.self] as [any PersistentModel.Type] {
            try? context.delete(model: type)
        }
        try? context.save()
    }

    private func first<T: PersistentModel>(_ type: T.Type) -> T? {
        let descriptor = FetchDescriptor<T>()
        return try? context.fetch(descriptor).first
    }

    @discardableResult
    private func insert<T: PersistentModel>(_ model: T) -> T {
        context.insert(model)
        try? context.save()
        return model
    }

    private func ensureSingletonsExist() {
        _ = rule()
        _ = filters()
        _ = overlay()
        _ = syncPrefs()
    }
}

private struct SeedSample {
    let title: String
    let city: String
    let country: String
    let tags: [String]
}
