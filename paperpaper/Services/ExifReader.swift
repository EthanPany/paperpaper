import Foundation
import ImageIO

struct ExtractedExif: Sendable {
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
}

enum ExifReader {
    static func read(from data: Data) -> ExtractedExif? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return read(from: src)
    }

    static func read(fromFile url: URL) -> ExtractedExif? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return read(from: src)
    }

    private static func read(from src: CGImageSource) -> ExtractedExif? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        var out = ExtractedExif()

        out.orientation = props[kCGImagePropertyOrientation] as? Int
        out.colorProfile = props[kCGImagePropertyProfileName] as? String

        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            out.cameraMake = tiff[kCGImagePropertyTIFFMake] as? String
            out.cameraModel = tiff[kCGImagePropertyTIFFModel] as? String
            out.software = tiff[kCGImagePropertyTIFFSoftware] as? String
        }

        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            out.lensMake = exif[kCGImagePropertyExifLensMake] as? String
            out.lensModel = exif[kCGImagePropertyExifLensModel] as? String
            out.focalLengthMM = (exif[kCGImagePropertyExifFocalLength] as? NSNumber)?.doubleValue
            out.focalLength35EquivMM = (exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.doubleValue
            out.apertureFStop = (exif[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue
            if let expSec = (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue {
                out.shutterSpeed = formatShutter(expSec)
            }
            if let isoArr = exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber], let first = isoArr.first {
                out.iso = first.intValue
            } else if let isoNum = exif[kCGImagePropertyExifISOSpeedRatings] as? NSNumber {
                out.iso = isoNum.intValue
            }
            if let dateStr = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                out.takenAt = exifDate(from: dateStr)
            }
        }

        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            if let lat = gps[kCGImagePropertyGPSLatitude] as? Double {
                let ref = gps[kCGImagePropertyGPSLatitudeRef] as? String
                out.latitude = (ref == "S") ? -lat : lat
            }
            if let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
                let ref = gps[kCGImagePropertyGPSLongitudeRef] as? String
                out.longitude = (ref == "W") ? -lon : lon
            }
            if let alt = gps[kCGImagePropertyGPSAltitude] as? Double {
                let ref = gps[kCGImagePropertyGPSAltitudeRef] as? Int
                out.altitude = (ref == 1) ? -alt : alt
            }
        }

        return out
    }

    private static func formatShutter(_ seconds: Double) -> String {
        guard seconds > 0 else { return "" }
        if seconds >= 1 {
            return String(format: "%.1fs", seconds)
        } else {
            let denom = Int((1.0 / seconds).rounded())
            return "1/\(denom)s"
        }
    }

    private static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static func exifDate(from string: String) -> Date? {
        exifFormatter.date(from: string)
    }
}

extension ExifRecord {
    convenience init(extracted: ExtractedExif) {
        self.init(
            cameraMake: extracted.cameraMake,
            cameraModel: extracted.cameraModel,
            lensMake: extracted.lensMake,
            lensModel: extracted.lensModel,
            focalLengthMM: extracted.focalLengthMM,
            focalLength35EquivMM: extracted.focalLength35EquivMM,
            apertureFStop: extracted.apertureFStop,
            shutterSpeed: extracted.shutterSpeed,
            iso: extracted.iso,
            takenAt: extracted.takenAt,
            latitude: extracted.latitude,
            longitude: extracted.longitude,
            altitude: extracted.altitude,
            orientation: extracted.orientation,
            colorProfile: extracted.colorProfile,
            software: extracted.software
        )
    }
}
