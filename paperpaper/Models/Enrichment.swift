import Foundation
import SwiftData

@Model
final class Enrichment {
    var buildingName: String?
    var architect: String?
    var year: Int?
    var style: String?
    var oneSentence: String?
    var confidenceRaw: String = Confidence.unknown.rawValue
    var enrichedAt: Date?
    var modelUsed: String?

    var photo: Photo?

    init(
        buildingName: String? = nil,
        architect: String? = nil,
        year: Int? = nil,
        style: String? = nil,
        oneSentence: String? = nil,
        confidence: Confidence = .unknown,
        enrichedAt: Date? = nil,
        modelUsed: String? = nil
    ) {
        self.buildingName = buildingName
        self.architect = architect
        self.year = year
        self.style = style
        self.oneSentence = oneSentence
        self.confidenceRaw = confidence.rawValue
        self.enrichedAt = enrichedAt
        self.modelUsed = modelUsed
    }

    var confidence: Confidence {
        get { Confidence(rawValue: confidenceRaw) ?? .unknown }
        set { confidenceRaw = newValue.rawValue }
    }
}
