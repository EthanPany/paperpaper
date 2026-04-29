import Foundation
import CoreLocation
import MapKit
import os

/// Coarse user location for the "prefer nearby" rotation mode. Single
/// authoritative source for both the toggle UI (which calls
/// `requestAuthorization()`) and the rotation engine (which calls
/// `currentRegion()` to decide what city/country to bias the search by).
///
/// We deliberately avoid keeping a CLLocationManager running. Each call
/// fires a one-shot `requestLocation()` and we cache the resolved city for
/// 24h in UserDefaults — the user moving across town doesn't matter for
/// "show me Spanish architecture instead of Brazilian."
@MainActor
final class LocationService: NSObject {
    static let shared = LocationService()

    struct Region: Sendable, Equatable {
        /// Free-form location string — typically "City, State" in the US or
        /// "City, Country" elsewhere. Used for UI ("Near: Barcelona, Spain")
        /// AND as the search-hint we prepend to Unsplash queries.
        var displayName: String

        var queryHint: String? { displayName.trimmedNonEmpty }
    }

    private let log = Logger(subsystem: "me.ethanpan.paperpaper", category: "location")
    private let manager = CLLocationManager()
    private var pending: CheckedContinuation<CLLocation?, Never>?

    private static let displayNameKey = "nearby.displayName"
    private static let cachedAtKey = "nearby.cachedAt"
    private static let cacheLifetime: TimeInterval = 60 * 60 * 24

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Called from the toggle. Returns the post-prompt status so the UI
    /// can show "denied — open System Settings."
    func requestAuthorization() async -> CLAuthorizationStatus {
        manager.requestWhenInUseAuthorization()
        // Yield once so the system prompt fires before we observe status.
        try? await Task.sleep(for: .milliseconds(50))
        return manager.authorizationStatus
    }

    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    /// Returns the cached region (or freshly resolves one). Callers must
    /// be tolerant of nil — location may be denied or unresolvable.
    func currentRegion() async -> Region? {
        if let cached = cachedRegion() {
            return cached
        }
        guard isAuthorized else {
            log.info("currentRegion: not authorized (status=\(self.manager.authorizationStatus.rawValue, privacy: .public))")
            return nil
        }
        guard let location = await requestOneShotLocation() else { return nil }
        let region = await reverseGeocode(location)
        if let region {
            persist(region)
        }
        return region
    }

    private var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorized:
            return true
        case .notDetermined, .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func cachedRegion() -> Region? {
        let cachedAt = UserDefaults.standard.double(forKey: Self.cachedAtKey)
        guard cachedAt > 0,
              Date.now.timeIntervalSince1970 - cachedAt < Self.cacheLifetime,
              let displayName = UserDefaults.standard.string(forKey: Self.displayNameKey)?.trimmedNonEmpty
        else {
            return nil
        }
        return Region(displayName: displayName)
    }

    private func persist(_ region: Region) {
        UserDefaults.standard.set(region.displayName, forKey: Self.displayNameKey)
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: Self.cachedAtKey)
    }

    private func requestOneShotLocation() async -> CLLocation? {
        await withCheckedContinuation { continuation in
            // Don't queue a second request behind a pending one.
            if pending != nil {
                continuation.resume(returning: nil)
                return
            }
            pending = continuation
            manager.requestLocation()

            // Safety net: if neither delegate callback fires within 10s
            // (system slow, edge-case daemon issue), resume nil so rotation
            // doesn't hang waiting for a location forever.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard let self, let stuck = self.pending else { return }
                self.pending = nil
                self.log.error("location request timed out after 10s")
                stuck.resume(returning: nil)
            }
        }
    }

    private func reverseGeocode(_ location: CLLocation) async -> Region? {
        // macOS 26 deprecated CLGeocoder; MKReverseGeocodingRequest replaces
        // it. MKAddress's `.shortAddress` is typically "City, State" in the
        // US or "City, Country" elsewhere — fine as both UI label and as a
        // search-hint to bias the Unsplash query.
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        do {
            let items = try await request.mapItems
            guard let item = items.first else { return nil }
            let raw: String? = item.address?.shortAddress
                ?? item.address?.fullAddress
                ?? item.name
            guard let displayName = raw?.trimmedNonEmpty else { return nil }
            return Region(displayName: displayName)
        } catch {
            log.error("reverse geocode failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        Task { @MainActor in
            self.pending?.resume(returning: location)
            self.pending = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.log.error("location request failed: \(error.localizedDescription, privacy: .public)")
            self.pending?.resume(returning: nil)
            self.pending = nil
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
