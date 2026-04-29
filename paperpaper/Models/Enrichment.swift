import Foundation
import SwiftData

@Model
final class Enrichment {
    var buildingName: String?
    var architect: String?
    var year: Int?
    var style: String?
    /// Legacy single-sentence caption. Kept for back-compat / SwiftData
    /// migration; new code reads `blurbShort` (which is set to the same value
    /// for forward-compat with old enrichments).
    var oneSentence: String?
    /// 1-sentence caption — fits systemSmall / systemMedium widgets.
    var blurbShort: String?
    /// 2–3 sentence intro — fits systemMedium / systemLarge.
    var blurbMedium: String?
    /// 3–5 sentence essay — only the largest surfaces (systemLarge, in-app).
    var blurbLong: String?
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
        blurbShort: String? = nil,
        blurbMedium: String? = nil,
        blurbLong: String? = nil,
        confidence: Confidence = .unknown,
        enrichedAt: Date? = nil,
        modelUsed: String? = nil
    ) {
        self.buildingName = buildingName
        self.architect = architect
        self.year = year
        self.style = style
        self.oneSentence = oneSentence
        self.blurbShort = blurbShort
        self.blurbMedium = blurbMedium
        self.blurbLong = blurbLong
        self.confidenceRaw = confidence.rawValue
        self.enrichedAt = enrichedAt
        self.modelUsed = modelUsed
    }

    var confidence: Confidence {
        get { Confidence(rawValue: confidenceRaw) ?? .unknown }
        set { confidenceRaw = newValue.rawValue }
    }
}
