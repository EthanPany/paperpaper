import Foundation
import SwiftData

@Model
final class SyncPrefs {
    var enabled: Bool = false
    var syncSettings: Bool = true
    var syncHistory: Bool = true
    var syncEnrichment: Bool = true
    var syncKeys: Bool = false
    var lastSyncAt: Date?

    init() {}
}
