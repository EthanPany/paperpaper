import Foundation
import SwiftData
import os
#if os(macOS)
import AppKit
#endif

/// Lightweight iCloud sync via NSUbiquitousKeyValueStore.
///
/// This is a deliberate "config-only" sync (option 1 from the design notes).
/// We do NOT mirror image bytes or enrichment text — those are local. We just
/// share:
///   • who is the primary device (one wins; others mirror)
///   • the most-recently-applied photo's Unsplash ID
///   • the rotation schedule (interval, day/night, days-of-week)
///
/// Image bytes flow through Unsplash (re-downloaded on each device), and
/// enrichment runs locally on each device (Ollama is free and fast).
///
/// Conflict model:
///   - Exactly one device is "primary" at a time, identified by a stable
///     per-Mac UUID. Primary writes to KVS; non-primary devices observe and
///     mirror. Multi-master races aren't possible because non-primary devices
///     never write the photoID / rule fields.
///   - Any device can promote itself by hitting "Make this Mac primary",
///     which overwrites `sync.primaryDeviceID`. The previous primary will see
///     the change on its next KVS notification and stop publishing.
@MainActor
@Observable
final class iCloudSyncCoordinator {
    static let shared = iCloudSyncCoordinator()

    @ObservationIgnored
    private let log = Logger(subsystem: "me.ethanpan.paperpaper", category: "icloud-sync")
    @ObservationIgnored
    private let kvs = NSUbiquitousKeyValueStore.default
    @ObservationIgnored
    private var observerToken: NSObjectProtocol?

    // MARK: - KVS keys
    private enum K {
        static let primaryID    = "sync.primaryDeviceID"
        static let primaryName  = "sync.primaryDeviceName"
        static let photoID      = "sync.currentPhotoID"
        static let photoAt      = "sync.currentPhotoUpdatedAt"
        /// Writer ID stamped on every photo / rule publish. Receivers reject
        /// writes whose writer doesn't match the current primary — kills the
        /// "stale write from previous primary lands after handoff" race.
        static let photoWriter  = "sync.currentPhotoWriterDeviceID"
        static let ruleJSON     = "sync.rotationRuleJSON"
        static let ruleAt       = "sync.rotationRuleUpdatedAt"
        static let ruleWriter   = "sync.rotationRuleWriterDeviceID"
    }

    // MARK: - Local state, surfaced to UI
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "sync.enabled")
            if isEnabled { claimPrimaryIfUnclaimed() }
        }
    }
    var primaryDeviceID: String?
    var primaryDeviceName: String?
    var lastSyncAt: Date?
    var lastError: String?

    /// Stable per-Mac UUID. Generated on first launch; lives in standard
    /// UserDefaults. We don't try to use the Mac's hardware UUID because
    /// privacy + entitlements; a random UUID is enough for "is this me?".
    @ObservationIgnored
    let deviceID: String
    @ObservationIgnored
    let deviceName: String

    var isPrimaryHere: Bool {
        guard let primary = primaryDeviceID else { return false }
        return primary == deviceID
    }

    // MARK: - Init

    private init() {
        let deviceIDKey = "sync.thisDeviceID"
        if let stored = UserDefaults.standard.string(forKey: deviceIDKey) {
            self.deviceID = stored
        } else {
            let new = UUID().uuidString
            UserDefaults.standard.set(new, forKey: deviceIDKey)
            self.deviceID = new
        }
        #if os(macOS)
        self.deviceName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        self.deviceName = ProcessInfo.processInfo.hostName
        #endif
        self.isEnabled = UserDefaults.standard.bool(forKey: "sync.enabled")
    }

    /// Wire up KVS observation and pull the current snapshot. Safe to call
    /// repeatedly — second + subsequent calls no-op. If the KVS entitlement
    /// is missing we log once and leave isEnabled false so the rest of the
    /// app keeps working without sync.
    func start() {
        guard observerToken == nil else { return }
        // KVS .synchronize() returns false when the entitlement is missing
        // ("BUG IN CLIENT OF KVS: Trying to initialize NSUbiquitousKeyValueStore
        //  without a store identifier"). Detect once and disable cleanly
        // instead of letting every publish call hit the same warning.
        guard kvs.synchronize() else {
            log.error("iCloud KVS unavailable — check the ubiquity-kvstore-identifier entitlement. Sync disabled.")
            isEnabled = false
            return
        }
        observerToken = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvs,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleExternalChange(note) }
        }
        refreshLocalStateFromKVS()
        if isEnabled { claimPrimaryIfUnclaimed() }
    }

    // MARK: - Public ops

    /// Promote THIS Mac to primary. The previous primary will notice on its
    /// next KVS notification and stop publishing.
    func makeThisDevicePrimary() {
        kvs.set(deviceID, forKey: K.primaryID)
        kvs.set(deviceName, forKey: K.primaryName)
        kvs.synchronize()
        primaryDeviceID = deviceID
        primaryDeviceName = deviceName
        log.notice("makeThisDevicePrimary: deviceID=\(self.deviceID, privacy: .public) name=\(self.deviceName, privacy: .public)")
    }

    /// Called by WallpaperApplier after a successful apply. Only writes when
    /// sync is enabled AND we're the primary — non-primary devices stay
    /// silent so two machines can't fight over the field.
    func publishPhotoApplied(unsplashID: String) {
        guard isEnabled, isPrimaryHere else { return }
        kvs.set(unsplashID, forKey: K.photoID)
        kvs.set(deviceID, forKey: K.photoWriter)
        kvs.set(Date.now.timeIntervalSince1970, forKey: K.photoAt)
        kvs.synchronize()
        lastSyncAt = .now
        log.info("publishPhotoApplied: id=\(unsplashID, privacy: .public)")
    }

    /// Called when the local rotation rule changes. Same primary-only gate.
    func publishRotationRule() {
        guard isEnabled, isPrimaryHere else { return }
        let rule = Store.shared.rule()
        let snap = RuleSnapshot.snapshotting(rule)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        kvs.set(data, forKey: K.ruleJSON)
        kvs.set(deviceID, forKey: K.ruleWriter)
        kvs.set(Date.now.timeIntervalSince1970, forKey: K.ruleAt)
        kvs.synchronize()
        lastSyncAt = .now
        log.info("publishRotationRule: interval=\(snap.intervalSeconds, privacy: .public)")
    }

    // MARK: - Internal

    private func claimPrimaryIfUnclaimed() {
        let existing = kvs.string(forKey: K.primaryID) ?? ""
        if existing.isEmpty {
            log.notice("no primary set in iCloud — claiming for this Mac")
            makeThisDevicePrimary()
        } else {
            primaryDeviceID = existing
            primaryDeviceName = kvs.string(forKey: K.primaryName)
        }
    }

    private func refreshLocalStateFromKVS() {
        primaryDeviceID = kvs.string(forKey: K.primaryID)
        primaryDeviceName = kvs.string(forKey: K.primaryName)
    }

    private func handleExternalChange(_ note: Notification) {
        guard isEnabled else { return }
        refreshLocalStateFromKVS()

        // Mirror photo + rule only on non-primary devices. The primary is
        // the source of truth; reading our own writes back would be a no-op
        // (we already applied the photo locally) and could cause a feedback
        // loop with the rotation engine.
        guard !isPrimaryHere else { return }

        let currentPrimary = kvs.string(forKey: K.primaryID) ?? ""

        // Rule first — the photo apply can take minutes to download, but the
        // schedule update should be instant.
        if let data = kvs.data(forKey: K.ruleJSON),
           let snap = try? JSONDecoder().decode(RuleSnapshot.self, from: data),
           writerIsCurrentPrimary(kvs.string(forKey: K.ruleWriter), expected: currentPrimary, kind: "rule") {
            applyRuleSnapshot(snap)
        }

        if let id = kvs.string(forKey: K.photoID), !id.isEmpty,
           writerIsCurrentPrimary(kvs.string(forKey: K.photoWriter), expected: currentPrimary, kind: "photo") {
            mirrorPhoto(unsplashID: id)
        }
    }

    /// Rejects writes from anyone who isn't the current primary. Catches the
    /// race where a previously-primary device finishes a publish AFTER the
    /// primary flag has been handed off to a different Mac. Without this, the
    /// stale write would clobber the new primary's state.
    private func writerIsCurrentPrimary(_ writer: String?, expected: String, kind: String) -> Bool {
        // Empty writer ID = an old write from before this field existed, or
        // the field was never written. Accept if we have a primary at all
        // (back-compat) — first-publish on the new primary will populate it.
        guard let writer, !writer.isEmpty else { return !expected.isEmpty }
        if writer == expected { return true }
        log.notice("ignoring stale \(kind, privacy: .public) write: writer=\(writer, privacy: .public) currentPrimary=\(expected, privacy: .public)")
        return false
    }

    private func applyRuleSnapshot(_ snap: RuleSnapshot) {
        let rule = Store.shared.rule()
        // Avoid no-op writes that would re-trigger the rotation engine.
        if snap.matches(rule) { return }
        snap.apply(to: rule)
        rule.updatedAt = .now
        try? Store.shared.context.save()
        RotationEngine.shared.startIfEnabled()
        lastSyncAt = .now
        log.notice("applied remote rule snapshot: interval=\(snap.intervalSeconds, privacy: .public)")
    }

    private func mirrorPhoto(unsplashID: String) {
        // Skip if it's already what we have locally — avoids re-downloading
        // when KVS notifies us about our own previously-mirrored apply.
        if let existing = WidgetPayload.read()?.unsplashID, existing == unsplashID {
            return
        }
        log.info("mirroring photo from primary: id=\(unsplashID, privacy: .public)")
        Task { [weak self] in
            do {
                let unsplash = try await UnsplashService.shared.photo(id: unsplashID)
                _ = try await WallpaperApplier.shared.apply(unsplash: unsplash)
                self?.lastSyncAt = .now
            } catch {
                self?.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self?.log.error("mirror failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// Codable mirror of the syncable subset of `RotationRule`. Per-machine
/// fields (spaceMode, etc.) are deliberately excluded.
private struct RuleSnapshot: Codable {
    var enabled: Bool
    var scheduleModeRaw: String
    var intervalSeconds: Int
    var alignToClock: Bool
    var specificMinutesOfDay: [Int]
    var daysOfWeekMask: Int
    var nightIntervalSeconds: Int
    var dayNightModeRaw: String
    var dayStartHour: Int
    var nightStartHour: Int
    var allowRepeats: Bool
    var repeatCooldownDays: Int
    var preferNearby: Bool

    static func snapshotting(_ rule: RotationRule) -> RuleSnapshot {
        RuleSnapshot(
            enabled: rule.enabled,
            scheduleModeRaw: rule.scheduleModeRaw,
            intervalSeconds: rule.intervalSeconds,
            alignToClock: rule.alignToClock,
            specificMinutesOfDay: rule.specificMinutesOfDay,
            daysOfWeekMask: rule.daysOfWeekMask,
            nightIntervalSeconds: rule.nightIntervalSeconds,
            dayNightModeRaw: rule.dayNightModeRaw,
            dayStartHour: rule.dayStartHour,
            nightStartHour: rule.nightStartHour,
            allowRepeats: rule.allowRepeats,
            repeatCooldownDays: rule.repeatCooldownDays,
            preferNearby: rule.preferNearby
        )
    }

    func matches(_ rule: RotationRule) -> Bool {
        enabled == rule.enabled
        && scheduleModeRaw == rule.scheduleModeRaw
        && intervalSeconds == rule.intervalSeconds
        && alignToClock == rule.alignToClock
        && specificMinutesOfDay == rule.specificMinutesOfDay
        && daysOfWeekMask == rule.daysOfWeekMask
        && nightIntervalSeconds == rule.nightIntervalSeconds
        && dayNightModeRaw == rule.dayNightModeRaw
        && dayStartHour == rule.dayStartHour
        && nightStartHour == rule.nightStartHour
        && allowRepeats == rule.allowRepeats
        && repeatCooldownDays == rule.repeatCooldownDays
        && preferNearby == rule.preferNearby
    }

    func apply(to rule: RotationRule) {
        rule.enabled = enabled
        rule.scheduleModeRaw = scheduleModeRaw
        rule.intervalSeconds = intervalSeconds
        rule.alignToClock = alignToClock
        rule.specificMinutesOfDay = specificMinutesOfDay
        rule.daysOfWeekMask = daysOfWeekMask
        rule.nightIntervalSeconds = nightIntervalSeconds
        rule.dayNightModeRaw = dayNightModeRaw
        rule.dayStartHour = dayStartHour
        rule.nightStartHour = nightStartHour
        rule.allowRepeats = allowRepeats
        rule.repeatCooldownDays = repeatCooldownDays
        rule.preferNearby = preferNearby
    }
}
