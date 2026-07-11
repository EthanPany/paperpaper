import Foundation
import Observation
import SwiftData
import CoreLocation
import AppKit
import os

@MainActor
@Observable
final class RotationEngine {
    static let shared = RotationEngine()

    @ObservationIgnored
    private let log = Logger(subsystem: "me.ethanpan.paperpaper", category: "rotation")

    private(set) var isRunning: Bool = false
    private(set) var lastError: String?
    private(set) var nextFireAt: Date?

    /// Outcome of the most recent rotation attempt, for the Schedule → Status
    /// debug panel. Lets the user see at a glance whether the last tick applied
    /// a new photo, was skipped (and why), or failed (and why).
    private(set) var lastTrigger: TriggerStatus?

    struct TriggerStatus: Sendable {
        enum Kind: Sendable { case rotated, skipped, failed }
        let kind: Kind
        /// Short human-readable detail, e.g. "On battery" or "No matching photos".
        let detail: String
        let at: Date

        var label: String {
            switch kind {
            case .rotated: return "Rotated — \(detail)"
            case .skipped: return "Skipped — \(detail)"
            case .failed:  return "Failed — \(detail)"
            }
        }
    }

    private func record(_ kind: TriggerStatus.Kind, _ detail: String) {
        lastTrigger = TriggerStatus(kind: kind, detail: detail, at: .now)
    }

    private var loopTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    /// Outcome of a single `rotate()` attempt. `.skipped` means a guard
    /// (offline / on battery) deferred the rotation — the loop then retries
    /// after a short backoff WITHOUT advancing the schedule baseline, so the
    /// wallpaper updates as soon as the blocking condition clears.
    private enum RotateOutcome {
        case rotated
        case failed
        case skipped(reason: String)
    }

    /// How long to wait before re-attempting a rotation that a guard skipped.
    /// Short enough to feel responsive when you plug in / reconnect, long
    /// enough not to spin.
    private static let skipRetrySeconds: TimeInterval = 120

    /// How long to wait before re-attempting a rotation that FAILED (Unsplash
    /// 5xx, momentary DNS, a transient decode). Longer than the guard backoff
    /// since a failure is less likely to clear in seconds, but far shorter than
    /// a whole interval so a blip doesn't cost an hour of stale wallpaper.
    private static let failureRetrySeconds: TimeInterval = 300

    /// Cap on consecutive fast retries after a failure. Once exhausted the
    /// failure is treated as persistent (bad key, no matching photos, an
    /// Unsplash outage) and we advance the schedule baseline so the loop falls
    /// back to the normal interval instead of re-fetching every 5 minutes
    /// indefinitely. Reset on any successful rotation.
    private static let maxFailureRetries = 3

    /// Number of back-to-back `.failed` rotations since the last success.
    private var consecutiveFailures = 0

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
        // Prompt for location up front when a location-aware mode is on, so the
        // permission dialog appears at the natural "I just turned on rotation"
        // moment — not silently deferred to the first fetch (which would fall
        // back to a worldwide query and never prompt at all if the status is
        // undetermined). No-ops once the status is already determined.
        let rule = Store.shared.rule()
        if rule.preferNearby || rule.matchDaylight {
            Task { await LocationService.shared.ensureAuthorized() }
        }
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
        // Manual rotation is an explicit user request — bypass the offline /
        // battery guards. If there's genuinely no network the fetch fails and
        // surfaces lastError, which is the honest outcome for a button press.
        _ = await rotate(force: true)
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
                let outcome = await rotate()
                // A guard-skipped catch-up must NOT advance the baseline, or
                // we'd swallow the missed rotation entirely — leave it past-due
                // so the loop below retries once the guard clears.
                if case .skipped = outcome {} else { lastRotationAt = .now }
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
            let outcome = await rotate()
            switch outcome {
            case .rotated:
                consecutiveFailures = 0
                lastRotationAt = .now
            case .failed:
                // A transient failure shouldn't cost a whole interval. Like the
                // skip path, leave the baseline unadvanced (so the next nextFire
                // is past-due) and back off briefly before retrying. Bound the
                // fast retries: once exhausted, treat the failure as persistent,
                // advance the baseline, and fall back to the normal schedule.
                if consecutiveFailures < Self.maxFailureRetries {
                    consecutiveFailures += 1
                    nextFireAt = .now.addingTimeInterval(Self.failureRetrySeconds)
                    try? await Task.sleep(for: .seconds(Self.failureRetrySeconds))
                    if Task.isCancelled { return }
                } else {
                    consecutiveFailures = 0
                    lastRotationAt = .now
                }
            case .skipped:
                // Don't advance the baseline — the rotation is still "owed".
                // Back off briefly, then loop: with the baseline unchanged the
                // next nextFire is already past-due, so we re-attempt as soon
                // as the backoff elapses (i.e. moments after reconnect / plug-in).
                nextFireAt = .now.addingTimeInterval(Self.skipRetrySeconds)
                try? await Task.sleep(for: .seconds(Self.skipRetrySeconds))
                if Task.isCancelled { return }
            }
        }
    }

    @discardableResult
    private func rotate(force: Bool = false) async -> RotateOutcome {
        // First-run gate: refuse to rotate without an Unsplash key. The
        // search call below would fail anyway, but it would do so on every
        // schedule tick — burning network and cluttering Console logs.
        // Surface a clear lastError instead so the menu bar status pill turns
        // red and the user knows where to go.
        guard let key = KeychainService.shared.get(.unsplashAccessKey), !key.isEmpty else {
            lastError = "Add an Unsplash Access Key in Settings → Connections."
            record(.failed, "No Unsplash access key")
            return .failed
        }

        // Rotation guards — automatic rotations only (manual "Rotate now"
        // passes force: true). Each sets a friendly lastError so the menu-bar
        // status explains the pause, then returns .skipped so the loop retries
        // soon instead of consuming the scheduled slot.
        if !force {
            let guardRule = Store.shared.rule()
            if guardRule.pauseWhenOffline && !NetworkMonitor.shared.isConnected {
                lastError = "Paused — no internet connection. Will resume when you're back online."
                record(.skipped, "Offline")
                return .skipped(reason: "offline")
            }
            if guardRule.pauseOnBattery && PowerService.isOnBattery {
                lastError = "Paused — running on battery. Will resume when you plug in."
                record(.skipped, "On battery")
                return .skipped(reason: "battery")
            }
        }

        do {
            let rule = Store.shared.rule()
            let filters = Store.shared.filters()
            let baseTopic = filters.topics.randomElement() ?? "architecture"
            // Default 0: each rotation fetches exactly one fresh photo for the
            // current-location query rather than serving from a pre-warmed
            // pool. Pre-fetching is opt-in — a populated cache otherwise lets
            // stale, non-local photos win the pick.
            let prefetchCount = UserDefaults.standard.object(forKey: "cache.prefetchCount") as? Int ?? 0
            let recentIDs = rule.allowRepeats ? [] : recentlyShownIDs(cooldownDays: rule.repeatCooldownDays)

            // How many candidates to pull per /photos/random call. The default
            // is ONE — which starves the dedup filter: if that single random
            // photo is in your cooldown window there's nothing else to pick, so
            // we fall through to re-showing a least-recently-seen duplicate.
            // When "no repeats" is on, pull a wider pool (~10) so an unseen
            // photo is overwhelmingly likely on the first call. When repeats are
            // allowed there's no reason to spend the extra Unsplash quota.
            let dedupPoolSize = 10
            let fetchCount = rule.allowRepeats ? (1 + prefetchCount) : max(1 + prefetchCount, dedupPoolSize)

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
            // The query rung that actually produced our candidates — passed to
            // the enrichment agent as provenance so it can tell a worldwide
            // fallback from a location-biased result (and stop guessing a
            // landmark from a silhouette). Tracks the last query that returned
            // anything, overwritten by the query that yields eligible photos.
            var matchedQuery: String?
            outer: for query in queries {
                for _ in 0..<3 {
                    do {
                        let batch = try await UnsplashService.shared.random(query: query, count: fetchCount)
                        // /photos/random samples WITH replacement — consecutive
                        // batches routinely repeat ids. Dedup so retries widen
                        // the pool instead of re-counting the same photos.
                        let known = Set(pool.map(\.id))
                        pool.append(contentsOf: batch.filter { !known.contains($0.id) })
                        if !batch.isEmpty { matchedQuery = query }
                        eligible = pool.filter { candidate in
                            acceptCandidate(candidate, filters: filters) && !recentIDs.contains(candidate.id)
                        }
                        if !eligible.isEmpty { matchedQuery = query; break outer }
                        // Empty batch = the query has no (more) photos; retrying
                        // the same query only burns rate limit. Next rung.
                        if batch.isEmpty { break }
                    } catch UnsplashError.http(let status, _) where status == 404 {
                        // No matches for this query — try the next one.
                        break
                    }
                }
            }

            // Rank the eligible pool instead of taking the first hit:
            //   • preferNearby → score by distance to the user (when both the
            //     user and the candidate have coordinates).
            //   • matchDaylight → additionally score brightness vs. the sun's
            //     altitude. Falls back transparently when signals are missing.
            // Force (manual "Rotate now") scores for *now*, not the next
            // scheduled fire — the user is looking at the screen right now.
            let scored: UnsplashPhoto? = (rule.preferNearby || rule.matchDaylight)
                ? await pickBest(in: eligible, rule: rule, referenceTime: force ? .now : (nextFireAt ?? .now))
                : eligible.first

            // Last-resort: if dedup blocked everything, fall back to the
            // *least-recently-shown* photo in the pool. This keeps rotation
            // moving instead of erroring out when the user's cooldown is
            // larger than Unsplash's random variety for that topic.
            let chosen: UnsplashPhoto?
            if let first = scored {
                chosen = first
            } else if !pool.isEmpty {
                // Dedup blocked every candidate — every photo the query ladder
                // returned is within the cooldown window. Re-show the one seen
                // longest ago rather than stalling. This is the ONLY path that
                // can repeat a photo while "no repeats" is on; log it so it's
                // explainable rather than looking like the toggle is ignored.
                let dup = pickLeastRecent(in: pool, filters: filters)
                log.info("no unseen photo across \(queries.count, privacy: .public) queries (\(pool.count, privacy: .public) candidates all within \(rule.repeatCooldownDays, privacy: .public)d cooldown) — re-showing least-recent \(dup?.id ?? "-", privacy: .public). Widen topics or lower cooldown to avoid.")
                chosen = dup
            } else {
                chosen = nil
            }
            guard let first = chosen else {
                // Every query in the ladder returned empty / 404 / dedup-only.
                // Surface that explicitly so the menu bar status is honest
                // about why the rotation didn't happen.
                lastError = "No matching photos on Unsplash for the current topics. Try broader topics in Settings → Schedule."
                record(.failed, "No matching photos")
                return .failed
            }

            let chosenLoc = [first.location?.city, first.location?.country]
                .compactMap { $0 }.joined(separator: ", ")
            let hasCoord = first.location?.position?.latitude != nil
            log.info("rotation chose \(first.id, privacy: .public) location=\(chosenLoc.isEmpty ? "(none — Unsplash returned no location)" : chosenLoc, privacy: .public) coords=\(hasCoord ? "yes" : "no", privacy: .public)")

            let applied = try await WallpaperApplier.shared.apply(unsplash: first)
            lastError = nil
            // Record the photo outcome now. Whether AI text lands is tracked
            // separately (WallpaperApplier.lastEnrichmentStatus) since the
            // enrichment runs asynchronously below and may take 5–30s.
            let aiOn = WallpaperApplier.shared.isEnrichmentConfigured
            record(.rotated, aiOn ? "New photo applied · AI text pending" : "New photo applied · AI text off")

            // Provenance for the enrichment agent: was the chosen photo from a
            // location-biased rung, or the worldwide topic fallback?
            // buildQueryLadder appends the bare topic last as the worldwide
            // fallback, so a matched query that isn't the bare topic means the
            // search was biased toward the user's area.
            let plainTopic: String = {
                let t = baseTopic.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? "architecture" : t
            }()
            let searchWasLocationBiased = rule.preferNearby && matchedQuery != nil && matchedQuery != plainTopic

            Task {
                await WallpaperApplier.shared.enrichIfNeeded(
                    applied,
                    searchQuery: matchedQuery,
                    searchWasLocationBiased: searchWasLocationBiased
                )
            }

            let remaining = eligible.filter { $0.id != first.id }.prefix(prefetchCount)
            for candidate in remaining {
                await WallpaperApplier.shared.preCache(candidate)
            }
            return .rotated
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            record(.failed, lastError ?? "Error")
            return .failed
        }
    }

    /// Rank the candidate pool and return the highest-scoring photo.
    ///
    /// Two signals, each used only when its toggle is on AND the data exists:
    ///   • location — distance from the user to the photo's Unsplash
    ///     coordinates (preferNearby). The query ladder only biases the
    ///     *search*; this is what actually prefers the geographically closest
    ///     candidate within the results.
    ///   • brightness — photo average color vs. the sun's altitude at
    ///     `referenceTime` (matchDaylight).
    /// Weighted sum (location slightly higher) — neither is a hard gate, so a
    /// perfect-brightness photo that's far away can still beat a bright noon
    /// shot from down the street. Candidates missing both signals stay in the
    /// running with a neutral score.
    private func pickBest(in pool: [UnsplashPhoto], rule: RotationRule, referenceTime: Date) async -> UnsplashPhoto? {
        guard !pool.isEmpty else { return nil }
        let userCoord = await LocationService.shared.currentCoordinate()
        let target = SolarMath.targetBrightness(at: referenceTime, coordinate: userCoord)

        let locationWeight = 0.6
        let brightnessWeight = 0.4

        var best: (photo: UnsplashPhoto, score: Double)?
        for photo in pool {
            var locScore: Double? = nil
            if rule.preferNearby,
               let user = userCoord,
               let lat = photo.location?.position?.latitude,
               let lon = photo.location?.position?.longitude {
                locScore = SolarMath.locationScore(userLat: user.latitude, userLon: user.longitude, photoLat: lat, photoLon: lon)
            }

            var brScore: Double? = nil
            if rule.matchDaylight, let b = SolarMath.brightness(fromHex: photo.color) {
                brScore = SolarMath.brightnessScore(candidate: b, target: target)
            }

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
        guard rule.preferNearby else {
            log.info("query ladder: preferNearby OFF → [\(topic, privacy: .public)] (worldwide)")
            return [topic]
        }
        guard let region = await LocationService.shared.currentRegion() else {
            log.info("query ladder: preferNearby ON but region unresolved (denied / no fix) → [\(topic, privacy: .public)] (worldwide)")
            return [topic]
        }
        // Locality-first, coarse-to-fine. The KEY rung is the bare city name
        // with NO topic. "architecture Avalon" matches almost nothing, but
        // "Avalon"/"Catalina" alone has 100+ photos — requiring BOTH the topic
        // and the place as keywords is exactly what made the search skip past
        // the user's own town straight to a worldwide topic query. So we try:
        //   1. "<topic> <city>"   — local AND on-topic (ideal)
        //   2. "<city>"           — local, topic dropped (keeps the wallpaper
        //                           nearby even when few local photos carry the
        //                           topic tag — the Catalina/Avalon case)
        //   3. "<topic> <region>" — broader region, back on-topic
        //   4. "<topic>"          — worldwide fallback
        let hints = region.searchHints
        var ladder: [String] = []
        if let primary = hints.first {
            ladder.append("\(topic) \(primary)")
            ladder.append(primary)
        }
        for hint in hints.dropFirst() {
            ladder.append("\(topic) \(hint)")
        }
        ladder.append(topic)
        // Dedup preserving order (topic may equal a hint; hints may collide).
        var seen = Set<String>()
        ladder = ladder.filter { seen.insert($0.lowercased()).inserted }
        log.info("query ladder: preferNearby ON, region=\(region.displayName, privacy: .public) → \(ladder.joined(separator: " | "), privacy: .public)")
        return ladder
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
