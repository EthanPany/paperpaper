import Foundation
import Observation
import SwiftData
import CoreLocation
import AppKit

@MainActor
@Observable
final class RotationEngine {
    static let shared = RotationEngine()

    private(set) var isRunning: Bool = false
    private(set) var lastError: String?
    private(set) var nextFireAt: Date?

    private var loopTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    private init() {
        // Restart the loop when the Mac wakes from sleep. `Task.sleep` is
        // measured in elapsed real time, but a long sleep mid-loop combined
        // with a closed lid means the rotation that "should" have fired during
        // sleep can land late. Cancelling and restarting the loop forces an
        // immediate past-due check so the wallpaper updates as soon as the
        // user is looking at the screen again.
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.start()
            }
        }
        self.wakeObserver = observer
    }

    /// Persisted across launches so re-opening the app does NOT trigger an
    /// immediate rotation if the schedule isn't due. Only consulted by the
    /// loop; not part of @Observable state.
    private static let lastRotationKey = "rotation.lastRotationAt"

    private var lastRotationAt: Date? {
        get {
            let raw = UserDefaults.standard.double(forKey: Self.lastRotationKey)
            return raw > 0 ? Date(timeIntervalSince1970: raw) : nil
        }
        set {
            UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Self.lastRotationKey)
        }
    }

    func startIfEnabled() {
        let rule = Store.shared.rule()
        if rule.enabled { start() } else { stop() }
    }

    /// Idempotent re-sync between persisted rule and engine state. Cheap to
    /// call repeatedly — invoked from menu-bar popover open, settings save,
    /// and iCloud-sync landings so `isRunning` / `nextFireAt` never drift.
    /// Also recomputes `nextFireAt` while paused so the UI can always show
    /// what the next fire WOULD be.
    func reconcile() {
        let rule = Store.shared.rule()
        if rule.enabled {
            if !isRunning { start() }
        } else {
            if isRunning { stop() }
        }
        let baseline = lastRotationAt ?? .now
        nextFireAt = Scheduler.nextFire(for: rule, after: baseline)
    }

    func start() {
        stop()
        isRunning = true
        lastError = nil
        loopTask = Task { [weak self] in
            await self?.loop()
        }
        // Both start() and stop() broadcast the rule to iCloud — together
        // they cover every entry point: launch (startIfEnabled → start/stop),
        // the schedule editor (which calls startIfEnabled after save), and
        // the bare enable/disable toggle in RotationView (which calls start
        // or stop directly). Coordinator no-ops if sync is disabled or this
        // Mac isn't primary, so this stays cheap.
        iCloudSyncCoordinator.shared.publishRotationRule()
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        isRunning = false
        // Keep `nextFireAt` populated based on the persisted rule so the
        // menu bar can show "would fire at HH:MM" while paused. Truly
        // clearing it is left to reconcile() / start() which both repopulate.
        let rule = Store.shared.rule()
        let baseline = lastRotationAt ?? .now
        nextFireAt = Scheduler.nextFire(for: rule, after: baseline)
        iCloudSyncCoordinator.shared.publishRotationRule()
    }

    func rotateNow() async {
        await rotate()
        lastRotationAt = .now
    }

    private func loop() async {
        // First-run anchor: if we've never rotated, mark "now" as the
        // baseline so the first rotation happens one full interval from
        // launch — not immediately. Without this, the very first launch
        // would rotate within seconds.
        if lastRotationAt == nil {
            lastRotationAt = .now
        }

        // Explicit past-due catch-up. When the app was closed (or the Mac
        // slept) across a scheduled fire, the next-fire computed from the
        // persisted `lastRotationAt` will be in the past — rotate once,
        // immediately, before entering the regular sleep/fire loop. This is
        // the guarantee we expose to users: re-opening paperpaper after a
        // missed rotation updates the wallpaper right away.
        let initialRule = Store.shared.rule()
        if initialRule.enabled {
            let baseline = lastRotationAt ?? .now
            let nextScheduled = Scheduler.nextFire(for: initialRule, after: baseline)
            if nextScheduled <= .now {
                await rotate()
                lastRotationAt = .now
            }
        }

        while !Task.isCancelled {
            let rule = Store.shared.rule()
            guard rule.enabled else {
                stop()
                return
            }
            // Schedule from the last actual rotation, not from "now". This
            // is what stops re-launching the app from triggering a fresh
            // rotation: if we rotated 20 minutes ago on a 1h schedule, we
            // sleep for the remaining 40 minutes instead of firing again.
            let baseline = lastRotationAt ?? .now
            let fire = Scheduler.nextFire(for: rule, after: baseline)
            nextFireAt = fire
            let interval = fire.timeIntervalSince(.now)
            if interval > 0 {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { return }
            }
            await rotate()
            lastRotationAt = .now
        }
    }

    private func rotate() async {
        // First-run gate: refuse to rotate without an Unsplash key. The
        // search call below would fail anyway, but it would do so on every
        // schedule tick — burning network and cluttering Console logs.
        // Surface a clear lastError instead so the menu bar status pill turns
        // red and the user knows where to go.
        guard let key = KeychainService.shared.get(.unsplashAccessKey), !key.isEmpty else {
            lastError = "Add an Unsplash Access Key in Settings → Connections."
            return
        }
        do {
            let rule = Store.shared.rule()
            let filters = Store.shared.filters()
            let baseTopic = filters.topics.randomElement() ?? "architecture"
            let prefetchCount = UserDefaults.standard.object(forKey: "cache.prefetchCount") as? Int ?? 3
            let recentIDs = rule.allowRepeats ? [] : recentlyShownIDs(cooldownDays: rule.repeatCooldownDays)

            // Build the query ladder: when "prefer nearby" is on, try the
            // user's city/country first, then fall back to the bare topic
            // so we still rotate when the user is in a place Unsplash has
            // few or no photos for.
            let queries = await buildQueryLadder(baseTopic: baseTopic, rule: rule)

            // For each query, try up to 3 batches before giving up — Unsplash
            // random returns a small page; if all are recent repeats, retry.
            // 404 from /photos/random means "no photos match this query" (not
            // a real error), so we fall through to the next query in the
            // ladder instead of bubbling up.
            var pool: [UnsplashPhoto] = []
            var eligible: [UnsplashPhoto] = []
            outer: for query in queries {
                for _ in 0..<3 {
                    do {
                        let batch = try await UnsplashService.shared.random(query: query, count: 1 + prefetchCount)
                        pool.append(contentsOf: batch)
                        eligible = pool.filter { candidate in
                            acceptCandidate(candidate, filters: filters) && !recentIDs.contains(candidate.id)
                        }
                        if !eligible.isEmpty { break outer }
                    } catch UnsplashError.http(let status, _) where status == 404 {
                        // No matches for this query — try the next one.
                        break
                    }
                }
            }

            // Match Daylight: instead of taking the first eligible candidate,
            // score each one by (location-distance + brightness-vs-sun-altitude)
            // and pick the highest. Falls back transparently when the user has
            // no location or when candidates lack lat/lon or color hex.
            let scored: UnsplashPhoto? = rule.matchDaylight
                ? await pickByDaylightScore(in: eligible, rule: rule)
                : eligible.first

            // Last-resort: if dedup blocked everything, fall back to the
            // *least-recently-shown* photo in the pool. This keeps rotation
            // moving instead of erroring out when the user's cooldown is
            // larger than Unsplash's random variety for that topic.
            let chosen: UnsplashPhoto?
            if let first = scored {
                chosen = first
            } else if !pool.isEmpty {
                chosen = pickLeastRecent(in: pool, filters: filters)
            } else {
                chosen = nil
            }
            guard let first = chosen else {
                // Every query in the ladder returned empty / 404 / dedup-only.
                // Surface that explicitly so the menu bar status is honest
                // about why the rotation didn't happen.
                lastError = "No matching photos on Unsplash for the current topics. Try broader topics in Settings → Schedule."
                return
            }

            let applied = try await WallpaperApplier.shared.apply(unsplash: first)
            lastError = nil

            Task {
                await WallpaperApplier.shared.enrichIfNeeded(applied)
            }

            let remaining = eligible.filter { $0.id != first.id }.prefix(prefetchCount)
            for candidate in remaining {
                await WallpaperApplier.shared.preCache(candidate)
            }
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Score the candidate pool by (location, brightness vs. sun altitude) and
    /// return the highest-scoring photo. Used when Match Daylight is enabled.
    ///
    /// The brightness target is derived from the sun's altitude at the *next
    /// scheduled rotation time* (so a photo that lands at sunset gets picked at
    /// the rotation tick that's about to run, not the one before). Location and
    /// brightness combine as a weighted sum (location weighted slightly higher,
    /// per the spec) — neither is a hard gate, so a perfect-brightness photo
    /// that's far away can still beat a bright noon shot from down the street.
    private func pickByDaylightScore(in pool: [UnsplashPhoto], rule: RotationRule) async -> UnsplashPhoto? {
        guard !pool.isEmpty else { return nil }
        let userCoord = await LocationService.shared.currentCoordinate()
        let referenceTime = nextFireAt ?? .now
        let target = SolarMath.targetBrightness(at: referenceTime, coordinate: userCoord)

        let locationWeight = 0.6
        let brightnessWeight = 0.4

        var best: (photo: UnsplashPhoto, score: Double)?
        for photo in pool {
            var locScore: Double? = nil
            if let user = userCoord,
               let lat = photo.location?.position?.latitude,
               let lon = photo.location?.position?.longitude {
                locScore = SolarMath.locationScore(userLat: user.latitude, userLon: user.longitude, photoLat: lat, photoLon: lon)
            }

            var brScore: Double? = nil
            if let b = SolarMath.brightness(fromHex: photo.color) {
                brScore = SolarMath.brightnessScore(candidate: b, target: target)
            }

            // If we have neither signal for this candidate, keep it in the
            // running with a neutral score so we don't filter it out entirely.
            let combined: Double
            switch (locScore, brScore) {
            case let (l?, b?): combined = locationWeight * l + brightnessWeight * b
            case let (l?, nil): combined = l
            case let (nil, b?): combined = b
            case (nil, nil): combined = 0.5
            }

            // Tiny jitter so identical scores don't always pick the same photo.
            let jitter = Double.random(in: 0...0.001)
            let total = combined + jitter
            if best == nil || total > best!.score {
                best = (photo, total)
            }
        }
        return best?.photo
    }

    /// Build the search-query ladder for one rotation. When `preferNearby`
    /// is on AND we can resolve a region, we try `"<topic> <region>"` first,
    /// then fall back to the bare topic so we don't get stuck if the user
    /// is somewhere Unsplash has no architecture photos for.
    private func buildQueryLadder(baseTopic: String, rule: RotationRule) async -> [String] {
        let trimmed = baseTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        let topic = trimmed.isEmpty ? "architecture" : trimmed
        guard rule.preferNearby,
              let hint = await LocationService.shared.currentRegion()?.queryHint
        else {
            return [topic]
        }
        return ["\(topic) \(hint)", topic]
    }

    /// Set of unsplash IDs shown within the cooldown window. Photos with
    /// `lastSeenAt == nil` are never blocked; that's how a fresh photo
    /// surfaces for the first time.
    private func recentlyShownIDs(cooldownDays: Int) -> Set<String> {
        guard cooldownDays > 0 else { return [] }
        let cutoff = Date.now.addingTimeInterval(-Double(cooldownDays) * 86400)
        let descriptor = FetchDescriptor<Photo>(predicate: #Predicate { $0.lastSeenAt != nil })
        guard let photos = try? Store.shared.context.fetch(descriptor) else { return [] }
        return Set(photos.compactMap { p -> String? in
            guard let seen = p.lastSeenAt, seen >= cutoff else { return nil }
            return p.unsplashID
        })
    }

    /// Pick the candidate whose stored `lastSeenAt` is oldest (or never seen).
    /// Used only when the dedup gate has blocked every fresh result.
    private func pickLeastRecent(in pool: [UnsplashPhoto], filters: FilterPrefs) -> UnsplashPhoto? {
        let acceptable = pool.filter { acceptCandidate($0, filters: filters) }
        let candidates = acceptable.isEmpty ? pool : acceptable
        return candidates.min { a, b in
            let lastA = Store.shared.photo(withUnsplashID: a.id)?.lastSeenAt ?? .distantPast
            let lastB = Store.shared.photo(withUnsplashID: b.id)?.lastSeenAt ?? .distantPast
            return lastA < lastB
        }
    }

    private func acceptCandidate(_ photo: UnsplashPhoto, filters: FilterPrefs) -> Bool {
        let aspect = Double(photo.width) / Double(max(photo.height, 1))
        if aspect < filters.minAspect || aspect > filters.maxAspect { return false }

        let tagTitles = (photo.tags ?? []).map(\.title.localizedLowercase)
        for excluded in filters.excludedTags where !excluded.isEmpty {
            if tagTitles.contains(excluded.localizedLowercase) { return false }
        }

        if let needle = filters.countryContains, !needle.isEmpty {
            let country = photo.location?.country?.localizedLowercase ?? ""
            if !country.contains(needle.localizedLowercase) { return false }
        }
        if let needle = filters.cameraContains, !needle.isEmpty {
            let camera = [photo.exif?.make, photo.exif?.model].compactMap { $0 }.joined(separator: " ").localizedLowercase
            if !camera.contains(needle.localizedLowercase) { return false }
        }
        return true
    }
}
