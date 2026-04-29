import Foundation
import SwiftData

@Model
final class Enrichment {
    var buildingName: String?
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
    var enrichedAt: Date?
    var modelUsed: String?

    var photo: Photo?

    init(
        buildingName: String? = nil,
        oneSentence: String? = nil,
        blurbShort: String? = nil,
        blurbMedium: String? = nil,
        blurbLong: String? = nil,
        enrichedAt: Date? = nil,
        modelUsed: String? = nil
    ) {
        self.buildingName = buildingName
        self.oneSentence = oneSentence
        self.blurbShort = blurbShort
        self.blurbMedium = blurbMedium
        self.blurbLong = blurbLong
        self.enrichedAt = enrichedAt
        self.modelUsed = modelUsed
    }
}
