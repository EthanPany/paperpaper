import Foundation
import SwiftData

@Model
final class ExifRecord {
    var cameraMake: String?
    var cameraModel: String?
    var lensMake: String?
    var lensModel: String?
    var focalLengthMM: Double?
    var focalLength35EquivMM: Double?
    var apertureFStop: Double?
    var shutterSpeed: String?
    var iso: Int?
    var takenAt: Date?
    var latitude: Double?
    var longitude: Double?
    var altitude: Double?
    var orientation: Int?
    var colorProfile: String?
    var software: String?

    var photo: Photo?

    init(
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        lensMake: String? = nil,
        lensModel: String? = nil,
        focalLengthMM: Double? = nil,
        focalLength35EquivMM: Double? = nil,
        apertureFStop: Double? = nil,
        shutterSpeed: String? = nil,
        iso: Int? = nil,
        takenAt: Date? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        altitude: Double? = nil,
        orientation: Int? = nil,
        colorProfile: String? = nil,
        software: String? = nil
    ) {
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lensMake = lensMake
        self.lensModel = lensModel
        self.focalLengthMM = focalLengthMM
        self.focalLength35EquivMM = focalLength35EquivMM
        self.apertureFStop = apertureFStop
        self.shutterSpeed = shutterSpeed
        self.iso = iso
        self.takenAt = takenAt
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.orientation = orientation
        self.colorProfile = colorProfile
        self.software = software
    }

    var hasGPS: Bool { latitude != nil && longitude != nil }

    var cameraLine: String {
        let parts = [cameraMake, cameraModel].compactMap { $0 }
        return parts.joined(separator: " ")
    }

    var lensLine: String {
        let parts = [lensMake, lensModel].compactMap { $0 }
        return parts.joined(separator: " ")
    }

    var shotLine: String {
        var bits: [String] = []
        if let focal = focalLengthMM { bits.append(String(format: "%.0fmm", focal)) }
        if let f = apertureFStop { bits.append(String(format: "f/%.1f", f)) }
        if let s = shutterSpeed { bits.append(s) }
        if let iso { bits.append("ISO \(iso)") }
        return bits.joined(separator: " · ")
    }
}
