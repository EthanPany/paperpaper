import Foundation
import SwiftData

@Model
final class HistoryEvent {
    var setAt: Date = Date.distantPast
    var displayID: String?
    var spaceTag: String?

    var photo: Photo?

    init(setAt: Date = .now, displayID: String? = nil, spaceTag: String? = nil) {
        self.setAt = setAt
        self.displayID = displayID
        self.spaceTag = spaceTag
    }
}
