import Foundation
import SwiftData

@Model
final class FilterPrefs {
    var topics: [String] = ["architecture"]
    var excludedTags: [String] = []
    var preferredColors: [String] = []
    var minAspect: Double = 1.0
    var maxAspect: Double = 2.5
    var cameraContains: String?
    var lensContains: String?
    var focalMinMM: Double?
    var focalMaxMM: Double?
    var countryContains: String?

    init() {}
}
