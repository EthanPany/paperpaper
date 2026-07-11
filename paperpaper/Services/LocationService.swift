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
        /// AND as the finest search-hint we prepend to Unsplash queries.
        var displayName: String
        /// Bare city ("Pacifica") — a middle rung; Unsplash often tags photos
        /// with just the city, no region suffix.
        var cityName: String?
        /// Coarse region — state or country ("California" / "United States").
        /// The crucial fallback rung: a small town has almost no Unsplash
        /// architecture, so without a broad regional hint the query collapses
        /// to a worldwide search and the wallpaper lands on another continent.
        var regionName: String?

        var queryHint: String? { displayName.trimmedNonEmpty }

        /// Search hints ordered most-specific → broadest, deduped, blanks
        /// dropped. Feeds the rotation query ladder. The bare city is preferred
        /// over `displayName` ("Pacifica" vs "Pacifica, CA") — Unsplash's text
        /// search treats both nearly identically, so querying both wastes a
        /// rung of rate limit on a near-duplicate search.
        var searchHints: [String] {
            var seen = Set<String>()
            return [cityName ?? displayName, regionName]
                .compactMap { $0?.trimmedNonEmpty }
                .filter { seen.insert($0.lowercased()).inserted }
        }
    }

    private let log = Logger(subsystem: "me.ethanpan.paperpaper", category: "location")
    private let manager = CLLocationManager()
    private var pending: CheckedContinuation<CLLocation?, Never>?
    /// Resumed by `locationManagerDidChangeAuthorization` once the user answers
    /// the system prompt. Lets `requestAndAwait()` actually wait for the
    /// decision instead of guessing after a fixed sleep.
    private var authContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?
    /// The single in-flight authorization request. Concurrent callers (e.g. the
    /// engine's proactive prompt on start AND a "Rotate now" that lands while
    /// the dialog is still open) all await this one Task, so every caller sees
    /// the user's actual decision rather than a premature `.notDetermined`.
    private var authTask: Task<CLAuthorizationStatus, Never>?

    // Persisted "last known location" — NOT a time-limited cache. Every
    // refresh resolves the live location first; these are only read as a
    // fallback when a live fix isn't available (denied / no signal / timeout).
    private static let displayNameKey = "nearby.displayName"
    private static let cityNameKey = "nearby.cityName"
    private static let regionNameKey = "nearby.regionName"
    private static let latitudeKey = "nearby.latitude"
    private static let longitudeKey = "nearby.longitude"

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Called from the toggle. Returns the post-prompt status so the UI
    /// can show "denied — open System Settings."
    func requestAuthorization() async -> CLAuthorizationStatus {
        await requestAndAwait()
    }

    /// Ensure we hold (or are denied) location authorization, prompting the
    /// user if the status is still undetermined. Returns true only when
    /// authorized. This is the entry point the rotation engine uses so the
    /// first location-aware rotation triggers the system prompt instead of
    /// silently falling back to a worldwide query.
    @discardableResult
    func ensureAuthorized() async -> Bool {
        if isAuthorized { return true }
        guard manager.authorizationStatus == .notDetermined else { return false }
        _ = await requestAndAwait()
        return isAuthorized
    }

    /// Trigger the system authorization prompt and wait for the user's answer.
    /// No-ops (returns the current status immediately) when already determined,
    /// so it's cheap to call from any entry point.
    private func requestAndAwait() async -> CLAuthorizationStatus {
        let current = manager.authorizationStatus
        guard current == .notDetermined else { return current }
        // Coalesce: if a prompt is already in flight, await its result instead
        // of bailing out early with the (still undetermined) current status.
        if let authTask { return await authTask.value }

        let task = Task { @MainActor [weak self] () -> CLAuthorizationStatus in
            guard let self else { return .notDetermined }
            return await withCheckedContinuation { (cont: CheckedContinuation<CLAuthorizationStatus, Never>) in
                self.authContinuation = cont
                self.manager.requestWhenInUseAuthorization()
                // Safety net: if no delegate callback arrives (system hiccup, or
                // the prompt is suppressed), resume after 30s so callers never hang.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    guard let self, let stuck = self.authContinuation else { return }
                    self.authContinuation = nil
                    self.log.error("authorization request timed out after 30s")
                    stuck.resume(returning: self.manager.authorizationStatus)
                }
            }
        }
        authTask = task
        let result = await task.value
        authTask = nil
        return result
    }

    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    /// Resolve the region for the CURRENT moment. Realtime-first: every call
    /// requests a live one-shot fix and reverse-geocodes it. Only when a live
    /// fix isn't available (denied, no signal, timeout) do we fall back to the
    /// last location we successfully resolved — never an expiring cache.
    /// Callers must tolerate nil (denied AND no prior fix).
    func currentRegion() async -> Region? {
        if await ensureAuthorized(),
           let location = await requestOneShotLocation(),
           let region = await reverseGeocode(location) {
            persist(region, coordinate: location.coordinate)
            return region
        }
        // Live location unavailable — use the last known region, if any.
        if let last = lastKnownRegion() {
            log.info("currentRegion: live fix unavailable — using last known \(last.displayName, privacy: .public)")
            return last
        }
        log.info("currentRegion: no live fix and no last-known region (status=\(self.manager.authorizationStatus.rawValue, privacy: .public))")
        return nil
    }

    /// Returns the user's coarse coordinate. Used by Match Daylight for solar
    /// altitude + per-photo distance scoring. Same realtime-first policy as
    /// `currentRegion()`: live fix when triggered, last-known coordinate only
    /// as a fallback.
    func currentCoordinate() async -> CLLocationCoordinate2D? {
        if await ensureAuthorized(), let location = await requestOneShotLocation() {
            // Remember as last-known even if reverse geocoding hasn't run.
            UserDefaults.standard.set(location.coordinate.latitude, forKey: Self.latitudeKey)
            UserDefaults.standard.set(location.coordinate.longitude, forKey: Self.longitudeKey)
            return location.coordinate
        }
        if let last = lastKnownCoordinate() {
            log.info("currentCoordinate: live fix unavailable — using last known")
            return last
        }
        return nil
    }

    /// The most recently resolved region WITHOUT triggering a new fix. A cheap
    /// read for callers that only want it as context (e.g. the enrichment agent
    /// labeling "where the user is viewing from") and shouldn't pay for a live
    /// GPS request. Returns the same persisted value `currentRegion()` falls
    /// back to — which rotation refreshes on every tick, so it's typically
    /// only seconds old by the time enrichment reads it.
    var cachedRegion: Region? { lastKnownRegion() }

    private func lastKnownCoordinate() -> CLLocationCoordinate2D? {
        guard UserDefaults.standard.object(forKey: Self.latitudeKey) != nil,
              UserDefaults.standard.object(forKey: Self.longitudeKey) != nil
        else { return nil }
        let lat = UserDefaults.standard.double(forKey: Self.latitudeKey)
        let lon = UserDefaults.standard.double(forKey: Self.longitudeKey)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private var isAuthorized: Bool {
        switch manager.authorizationStatus {
        // `.authorizedWhenInUse` is what macOS actually grants in response to
        // `requestWhenInUseAuthorization()` — omitting it here was the bug that
        // made every location-aware rotation silently fall back to a worldwide
        // query (generic architecture, never near you). `.authorizedAlways` /
        // `.authorized` cover the legacy macOS "Always" grant.
        case .authorizedAlways, .authorizedWhenInUse, .authorized:
            return true
        case .notDetermined, .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    /// Last successfully-resolved region — the fallback when no live fix is
    /// available. No expiry: a day-old "San Francisco" beats a worldwide query.
    private func lastKnownRegion() -> Region? {
        guard let displayName = UserDefaults.standard.string(forKey: Self.displayNameKey)?.trimmedNonEmpty
        else { return nil }
        // Self-heal: an earlier build persisted the precise STREET address
        // ("603 Farallon Ave, Pacifica"). Street addresses start with a house
        // number; a city-level name never does. Reject it so we don't serve a
        // bad (and privacy-leaking) hint — better to return nil and let the
        // query fall back to worldwide than leak the doorstep.
        if let first = displayName.first, first.isNumber {
            log.info("last-known region looks like a street address (\(displayName, privacy: .public)) — ignoring")
            return nil
        }
        return Region(
            displayName: displayName,
            cityName: UserDefaults.standard.string(forKey: Self.cityNameKey)?.trimmedNonEmpty,
            regionName: UserDefaults.standard.string(forKey: Self.regionNameKey)?.trimmedNonEmpty
        )
    }

    private func persist(_ region: Region, coordinate: CLLocationCoordinate2D) {
        let defaults = UserDefaults.standard
        defaults.set(region.displayName, forKey: Self.displayNameKey)
        if let city = region.cityName { defaults.set(city, forKey: Self.cityNameKey) }
        else { defaults.removeObject(forKey: Self.cityNameKey) }
        if let area = region.regionName { defaults.set(area, forKey: Self.regionNameKey) }
        else { defaults.removeObject(forKey: Self.regionNameKey) }
        defaults.set(coordinate.latitude, forKey: Self.latitudeKey)
        defaults.set(coordinate.longitude, forKey: Self.longitudeKey)
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
        // macOS 26 deprecated CLGeocoder; MKReverseGeocodingRequest replaces it.
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        do {
            let items = try await request.mapItems
            guard let item = items.first else { return nil }

            // Resolve to CITY granularity — NOT the raw street address.
            // `MKAddress.shortAddress` for a precise fix is the nearest postal
            // address ("603 Farallon Ave, Pacifica"), which is wrong on two
            // counts: (1) it's a useless Unsplash search hint — there are zero
            // photos tagged to a street, so the location query silently falls
            // through to a worldwide topic search and the wallpaper ends up
            // nowhere near you; (2) it leaks your exact street into the UI label
            // and over the network. "Prefer nearby" means city, not doorstep.
            //
            // `cityWithContext` is MapKit's city-plus-disambiguation string
            // ("Pacifica, CA" / "Barcelona, Spain") — precisely that granularity,
            // and the non-deprecated replacement for the old `.placemark`.
            // `cityName` / `regionName` give the broader fallback rungs.
            let reps = item.addressRepresentations
            let cityCtx = reps?.cityWithContext?.trimmedNonEmpty
            let cityName = reps?.cityName?.trimmedNonEmpty
            let regionName = reps?.regionName?.trimmedNonEmpty

            guard let displayName = cityCtx ?? cityName ?? regionName else {
                log.info("reverse geocode: no city-level component resolved")
                return nil
            }
            log.info("reverse geocode resolved region: \(displayName, privacy: .public) city=\(cityName ?? "-", privacy: .public) region=\(regionName ?? "-", privacy: .public)")
            return Region(displayName: displayName, cityName: cityName, regionName: regionName)
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

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            // This fires once with the current status right after the delegate
            // is assigned. Ignore that initial `.notDetermined` callback —
            // only a terminal decision (authorized / denied) should resume a
            // pending `requestAndAwait()`.
            guard manager.authorizationStatus != .notDetermined else { return }
            self.authContinuation?.resume(returning: manager.authorizationStatus)
            self.authContinuation = nil
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
