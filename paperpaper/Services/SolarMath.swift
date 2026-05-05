import Foundation
import CoreLocation

/// Sun-position math + brightness scoring used by the Match Daylight feature.
/// Inline so we don't carry a Swift Package just to compute one altitude angle.
/// Accuracy is well within what we need (a few arc-minutes) — we map altitude
/// to a 0..1 target brightness, so sub-degree error is invisible.
enum SolarMath {
    /// Sun altitude in degrees above the horizon at `date` for `lat`/`lon`.
    /// Negative means below horizon (night). Based on NOAA's simplified formula.
    static func solarAltitudeDegrees(at date: Date, latitude lat: Double, longitude lon: Double) -> Double {
        let jd = julianDay(date)
        let n = jd - 2451545.0
        let L = (280.460 + 0.9856474 * n).truncatingRemainder(dividingBy: 360)
        let g = ((357.528 + 0.9856003 * n).truncatingRemainder(dividingBy: 360)) * .pi / 180
        let lambda = (L + 1.915 * sin(g) + 0.020 * sin(2 * g)) * .pi / 180
        let epsilon = (23.439 - 0.0000004 * n) * .pi / 180
        let ra = atan2(cos(epsilon) * sin(lambda), cos(lambda))
        let decl = asin(sin(epsilon) * sin(lambda))
        let gmst = (18.697374558 + 24.06570982441908 * n).truncatingRemainder(dividingBy: 24)
        let lst = (gmst * 15 + lon).truncatingRemainder(dividingBy: 360) * .pi / 180
        var ha = lst - ra
        if ha > .pi { ha -= 2 * .pi }
        if ha < -.pi { ha += 2 * .pi }
        let latRad = lat * .pi / 180
        let altitude = asin(sin(latRad) * sin(decl) + cos(latRad) * cos(decl) * cos(ha))
        return altitude * 180 / .pi
    }

    /// Continuous target brightness 0..1 from sun altitude.
    /// Below -6° (civil twilight) → ~0.05. Above ~50° → ~0.95. Smooth in between.
    static func targetBrightness(forAltitudeDegrees altitude: Double) -> Double {
        let clamped = max(-12.0, min(60.0, altitude))
        let t = (clamped + 12.0) / 72.0 // 0..1
        return 0.05 + 0.90 * t
    }

    /// Convenience: target brightness for a date+location, with no-location fallback
    /// to a rough sine over the local clock (sunrise≈6, noon=12, sunset≈18).
    static func targetBrightness(at date: Date, coordinate: CLLocationCoordinate2D?) -> Double {
        if let c = coordinate {
            let alt = solarAltitudeDegrees(at: date, latitude: c.latitude, longitude: c.longitude)
            return targetBrightness(forAltitudeDegrees: alt)
        }
        let cal = Calendar.autoupdatingCurrent
        let comps = cal.dateComponents([.hour, .minute], from: date)
        let frac = Double(comps.hour ?? 12) + Double(comps.minute ?? 0) / 60.0
        let phase = (frac - 6.0) / 12.0 * .pi // sunrise→sunset → 0..π
        let s = sin(max(0, min(.pi, phase)))
        return 0.05 + 0.90 * s
    }

    /// Brightness 0..1 from an Unsplash `color` hex like "#a4b3c0" (or "a4b3c0").
    /// Uses Rec. 709 luma. Returns nil if the string can't be parsed.
    static func brightness(fromHex hex: String?) -> Double? {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xFF) / 255.0
        let g = Double((v >> 8) & 0xFF) / 255.0
        let b = Double(v & 0xFF) / 255.0
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// Score 0..1 for how close a photo's location is to the user.
    /// Smooth falloff — 0km→1.0, ~50km→0.5, ~500km→0.09.
    static func locationScore(userLat: Double, userLon: Double, photoLat: Double, photoLon: Double) -> Double {
        let user = CLLocation(latitude: userLat, longitude: userLon)
        let photo = CLLocation(latitude: photoLat, longitude: photoLon)
        let km = user.distance(from: photo) / 1000.0
        return 1.0 / (1.0 + km / 50.0)
    }

    /// Score 0..1 for how close a candidate's brightness matches the target.
    static func brightnessScore(candidate: Double, target: Double) -> Double {
        1.0 - abs(candidate - target)
    }

    private static func julianDay(_ date: Date) -> Double {
        // Unix epoch (1970-01-01 UTC) = JD 2440587.5
        return date.timeIntervalSince1970 / 86400.0 + 2440587.5
    }
}
