import Foundation
import SwiftData

@Model
final class Photo {
    var unsplashID: String = ""
    var thumbURLString: String = ""
    var regularURLString: String = ""
    var fullURLString: String = ""
    var rawURLString: String?
    var authorName: String = ""
    var authorUsername: String?
    var authorProfileURLString: String?
    var photoDescription: String?
    var altDescription: String?
    var tags: [String] = []
    var locationName: String?
    var locationCity: String?
    var locationCountry: String?
    var width: Int = 0
    var height: Int = 0
    var hexColor: String?
    var likes: Int = 0
    var firstSeenAt: Date = Date.distantPast
    var lastSeenAt: Date?
    var favoritedAt: Date?
    var hiddenAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \ExifRecord.photo)
    var exif: ExifRecord?

    @Relationship(deleteRule: .cascade, inverse: \Enrichment.photo)
    var enrichment: Enrichment?

    @Relationship(deleteRule: .cascade, inverse: \HistoryEvent.photo)
    var history: [HistoryEvent]? = []

    init(
        unsplashID: String,
        thumbURL: URL,
        regularURL: URL,
        fullURL: URL,
        rawURL: URL? = nil,
        authorName: String,
        authorUsername: String? = nil,
        authorProfileURL: URL? = nil,
        photoDescription: String? = nil,
        altDescription: String? = nil,
        tags: [String] = [],
        locationName: String? = nil,
        locationCity: String? = nil,
        locationCountry: String? = nil,
        width: Int,
        height: Int,
        hexColor: String? = nil,
        likes: Int = 0,
        firstSeenAt: Date = .now
    ) {
        self.unsplashID = unsplashID
        self.thumbURLString = thumbURL.absoluteString
        self.regularURLString = regularURL.absoluteString
        self.fullURLString = fullURL.absoluteString
        self.rawURLString = rawURL?.absoluteString
        self.authorName = authorName
        self.authorUsername = authorUsername
        self.authorProfileURLString = authorProfileURL?.absoluteString
        self.photoDescription = photoDescription
        self.altDescription = altDescription
        self.tags = tags
        self.locationName = locationName
        self.locationCity = locationCity
        self.locationCountry = locationCountry
        self.width = width
        self.height = height
        self.hexColor = hexColor
        self.likes = likes
        self.firstSeenAt = firstSeenAt
    }

    var thumbURL: URL? { URL(string: thumbURLString) }
    var regularURL: URL? { URL(string: regularURLString) }
    var fullURL: URL? { URL(string: fullURLString) }
    var rawURL: URL? { rawURLString.flatMap(URL.init(string:)) }
    var authorProfileURL: URL? { authorProfileURLString.flatMap(URL.init(string:)) }

    var aspect: Double {
        guard height > 0 else { return 1 }
        return Double(width) / Double(height)
    }

    var areaText: String {
        [locationCity, locationCountry].compactMap { $0 }.joined(separator: ", ").nilIfEmpty ?? locationName ?? ""
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
