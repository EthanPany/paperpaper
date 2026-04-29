import Foundation
import SwiftData
import os
import Darwin
#if canImport(WidgetKit)
import WidgetKit
#endif
#if canImport(AppKit)
import AppKit
#endif

@MainActor
@Observable
final class WallpaperApplier {
    static let shared = WallpaperApplier()

    /// True while the architecture agent is actively talking to Ollama.
    /// Bound to spinners in NowView and MenuBarContent so the user sees
    /// the click registered (Ollama enrichment can take 5–30s).
    var isEnriching: Bool = false

    @ObservationIgnored
    private let log = Logger(subsystem: "ep.paperpaper", category: "widget-sync")

    /// Set while apply()/reapply() is mid-flight. WallpaperWatcher reads this
    /// to skip its poll-based sync — otherwise a 30s tick or activeSpace
    /// change firing between setOnAllScreens and writeWidgetPayload would
    /// snapshot a half-applied state and overwrite the new payload.
    private var suppressWatcherSync = false

    func localFileURL(for unsplashID: String) -> URL {
        ImageCache.shared.fileURL(for: unsplashID)
    }

    @discardableResult
    func apply(unsplash: UnsplashPhoto) async throws -> Photo {
        let rawFile = try await ensureDownloaded(id: unsplash.id, url: unsplash.urls.full)
        ImageCache.shared.touch(rawFile)

        let photo = Store.shared.upsert(Photo(unsplash: unsplash))

        if photo.exif == nil, let data = try? Data(contentsOf: rawFile), let extracted = ExifReader.read(from: data) {
            let exif = ExifRecord(extracted: extracted)
            exif.photo = photo
            Store.shared.context.insert(exif)
            try? Store.shared.context.save()
        }

        let appliedFile = (try? composeOverlayIfEnabled(for: photo, sourceFile: rawFile)) ?? rawFile

        Store.shared.recordShown(photo)

        // Order matters: set the wallpaper BEFORE writing the widget payload.
        // WallpaperWatcher polls the macOS desktop URL on a 30s tick + on
        // activeSpaceDidChange / didBecomeActive — if we wrote the widget first
        // and the watcher fired in the gap before setOnAllScreens completes, it
        // would map the still-stale desktop URL back to the OLD photo and
        // overwrite our just-written NEW payload. Setting wallpaper first means
        // the desktop URL already matches by the time we touch the widget.
        suppressWatcherSync = true
        defer { suppressWatcherSync = false }

        #if os(macOS)
        try WallpaperService.shared.setOnAllScreens(imageURL: appliedFile)
        // Same cross-Space propagation as reapply — rotation should also
        // visit the user's other Spaces over the next 5 minutes.
        armCrossSpaceReapply(photo: photo, file: appliedFile, ttl: 300)
        #endif

        writeWidgetPayload(for: photo, file: appliedFile)

        // Broadcast to other iCloud devices when this Mac is the primary.
        // Coordinator no-ops if sync is disabled or another Mac is primary.
        iCloudSyncCoordinator.shared.publishPhotoApplied(unsplashID: photo.unsplashID)

        enforceCacheCap()
        return photo
    }

    /// Re-set the macOS desktop image from the most recently applied photo,
    /// without picking a new one. Used by the menu-bar "Reapply wallpaper"
    /// action — handy when macOS dropped the image after a Space change /
    /// display reconfigure / sleep cycle.
    @discardableResult
    func reapplyMostRecent() async -> Bool {
        let descriptor = FetchDescriptor<Photo>(sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)])
        guard let latest = try? Store.shared.context.fetch(descriptor).first(where: { $0.lastSeenAt != nil }) else {
            log.error("reapplyMostRecent: no applied photo on file")
            return false
        }
        do {
            return try await reapply(photo: latest)
        } catch {
            log.error("reapplyMostRecent failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    func reapply(photo: Photo) async throws -> Bool {
        guard let fullURL = photo.fullURL ?? photo.regularURL else { return false }
        let rawFile = try await ensureDownloaded(id: photo.unsplashID, url: fullURL)
        ImageCache.shared.touch(rawFile)

        let appliedFile = (try? composeOverlayIfEnabled(for: photo, sourceFile: rawFile)) ?? rawFile

        Store.shared.recordShown(photo)

        // See apply(unsplash:) — wallpaper first, then widget, with the
        // watcher gate held shut for the duration so a concurrent space-
        // change or 30s-tick can't snapshot a half-applied state.
        suppressWatcherSync = true
        defer { suppressWatcherSync = false }

        #if os(macOS)
        try WallpaperService.shared.setOnAllScreens(imageURL: appliedFile)
        // macOS only sets wallpaper on the CURRENT Space — there's no public
        // API to set across all Spaces simultaneously. Arm a one-shot
        // listener so the next time the user switches Spaces (within 5
        // minutes) we re-apply this photo automatically. Net effect: a
        // single click of "Reapply" eventually propagates to every Space
        // the user visits.
        armCrossSpaceReapply(photo: photo, file: appliedFile, ttl: 300)
        #endif

        // forceReload=true: the user asked for this explicitly, so refresh
        // the widget timeline even if the payload bytes are unchanged. The
        // most common reason fields differ at this point is that an async
        // enrichment landed AFTER the last automatic write — without
        // forceReload, the widget would keep rendering the pre-enrichment
        // payload.
        writeWidgetPayload(for: photo, file: appliedFile, forceReload: true)

        // Reapplied photo might be one the rotation engine never enriched
        // (e.g. user picked it manually from Discover). Kick off the agent
        // so the widget gets caught up — no-op when already enriched.
        kickOffEnrichmentIfMissing(photo)

        enforceCacheCap()
        return true
    }

    #if os(macOS)
    /// Tracks a "reapply on next Space change" intent. Set by `reapply()`
    /// and consumed by `applyPendingCrossSpaceReapply()` on the next
    /// `activeSpaceDidChange`. Holds onto an `expiresAt` so a stale intent
    /// from hours ago doesn't overwrite the user's intentional later
    /// rotations.
    private struct PendingCrossSpaceReapply {
        let photoID: PersistentIdentifier
        let imageURL: URL
        let expiresAt: Date
    }
    private var pendingCrossSpaceReapply: PendingCrossSpaceReapply?
    private var spaceObserverToken: NSObjectProtocol?

    private func armCrossSpaceReapply(photo: Photo, file: URL, ttl: TimeInterval) {
        pendingCrossSpaceReapply = PendingCrossSpaceReapply(
            photoID: photo.persistentModelID,
            imageURL: file,
            expiresAt: .now.addingTimeInterval(ttl)
        )
        // Install the observer once.
        if spaceObserverToken == nil {
            spaceObserverToken = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    await WallpaperApplier.shared.applyPendingCrossSpaceReapply()
                }
            }
        }
    }

    private func applyPendingCrossSpaceReapply() async {
        guard let pending = pendingCrossSpaceReapply else { return }
        if pending.expiresAt < .now {
            pendingCrossSpaceReapply = nil
            return
        }
        // Re-apply on the (now-active) other Space. Don't disarm — the user
        // may visit several more Spaces; each will get the photo too. The
        // TTL limits how long this propagates.
        do {
            try WallpaperService.shared.setOnAllScreens(imageURL: pending.imageURL)
            log.info("cross-space reapply: applied to current space")
        } catch {
            log.error("cross-space reapply failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    #endif

    /// Warm both image cache AND enrichment for a candidate the user hasn't
    /// rotated to yet. Called from RotationEngine's prefetch loop, so by the
    /// time the user actually flips to one of these the heavy Ollama call has
    /// already (most likely) finished — the widget then updates once with the
    /// final blurbs instead of "basic info → blurbs land 30s later."
    ///
    /// preCache itself doesn't await the enrichment Task — that would serialise
    /// the rotation engine's prefetch loop on Ollama. enrichIfNeeded is per-
    /// photo deduped, so the eventual `apply()`-driven call for the same
    /// photo joins the in-flight task instead of starting a parallel one.
    func preCache(_ unsplash: UnsplashPhoto) async {
        guard let rawFile = try? await ensureDownloaded(id: unsplash.id, url: unsplash.urls.full) else {
            return
        }
        let photo = Store.shared.upsert(Photo(unsplash: unsplash))
        // Pull EXIF in here too so the agent gets GPS / camera data when
        // it runs in the background — matches what apply() does post-download.
        if photo.exif == nil,
           let data = try? Data(contentsOf: rawFile),
           let extracted = ExifReader.read(from: data) {
            let exif = ExifRecord(extracted: extracted)
            exif.photo = photo
            Store.shared.context.insert(exif)
            try? Store.shared.context.save()
        }
        // Don't await — let the rotation engine's prefetch loop continue.
        // enrichIfNeeded is idempotent + per-photo deduped so the later
        // apply-side call will join this task or no-op if it finished.
        if photo.enrichment?.enrichedAt == nil {
            Task { [weak self] in await self?.enrichIfNeeded(photo) }
        }
    }

    /// Dumps the current on-disk widget payload field-by-field to the unified
    /// log. Hooked to a "Refresh widget" menu-bar button. Use Console.app with
    /// `subsystem:ep.paperpaper category:widget-sync` to inspect — this is the
    /// fastest way to disambiguate "WidgetKit isn't refreshing" from "the
    /// payload is empty so there's nothing to render."
    func logWidgetPayloadForDiagnostics() {
        guard let payload = WidgetPayload.read() else {
            log.error("DIAG: WidgetPayload.read() returned nil — App Group unreachable or never written")
            return
        }
        log.info("DIAG payload id=\(payload.unsplashID, privacy: .public) image=\(payload.imageFileName, privacy: .public)")
        log.info("DIAG title-chain building=\(payload.buildingName ?? "-", privacy: .public) photoDesc=\(payload.photoDescription ?? "-", privacy: .public) alt=\(payload.altDescription ?? "-", privacy: .public) area=\(payload.area, privacy: .public) loc=\(payload.locationName ?? "-", privacy: .public)")
        log.info("DIAG enrichment architect=\(payload.architect ?? "-", privacy: .public) year=\(payload.year ?? -1) sentence=\(payload.oneSentence ?? "-", privacy: .public)")
        log.info("DIAG exif camera=\(payload.cameraLine ?? "-", privacy: .public) lens=\(payload.lensLine ?? "-", privacy: .public) shot=\(payload.shotLine ?? "-", privacy: .public)")
        if let url = payload.resolvedImageURL() {
            let exists = FileManager.default.fileExists(atPath: url.path)
            log.info("DIAG image url=\(url.path, privacy: .public) exists=\(exists, privacy: .public)")
        }
    }

    /// Reconcile the widget with whatever the macOS desktop is currently
    /// showing. Called from launch, from `WallpaperWatcher` ticks, and from
    /// any "Refresh widget" UI. Idempotent — no widget reload happens when
    /// the resulting payload matches what's already written.
    ///
    /// Three cases:
    ///   1. macOS desktop URL maps back to a Photo we know — use that
    ///      Photo's full enrichment.
    ///   2. We can't read the desktop URL, but we have a most-recent-applied
    ///      Photo — fall back to it.
    ///   3. Desktop is showing an external image we don't own — write a
    ///      minimal payload pointing at that file directly.
    func syncWidgetFromCurrent(forceReload: Bool = false) {
        // Drop the call entirely when an apply()/reapply() is in flight —
        // otherwise we'd race with the wallpaper-then-widget sequence and
        // snapshot stale desktop state.
        if suppressWatcherSync {
            log.info("syncWidgetFromCurrent: skipped (apply in flight)")
            return
        }
        #if os(macOS)
        let desktopURL = WallpaperService.shared.allScreens.first.flatMap {
            WallpaperService.shared.currentImageURL(for: $0)
        }
        if let url = desktopURL, let photo = matchPhoto(for: url) {
            writeWidgetPayload(for: photo, file: url, forceReload: forceReload)
            kickOffEnrichmentIfMissing(photo)
            return
        }
        if let url = desktopURL, isExternal(url) {
            writeExternalPayload(file: url, forceReload: forceReload)
            return
        }
        #endif

        // Fall back to most recent applied photo (case 2 / non-macOS).
        let descriptor = FetchDescriptor<Photo>(sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)])
        guard let latest = try? Store.shared.context.fetch(descriptor).first(where: { $0.lastSeenAt != nil }) else {
            log.info("syncWidgetFromCurrent: no applied photo yet, no desktop URL")
            return
        }
        let style = Store.shared.overlay()
        let raw = ImageCache.shared.fileURL(for: latest.unsplashID)
        let overlay = ImageCache.shared.dir.appending(path: "\(latest.unsplashID).overlay.jpg")
        let preferred: URL = {
            if style.enabled, FileManager.default.fileExists(atPath: overlay.path) { return overlay }
            return raw
        }()
        writeWidgetPayload(for: latest, file: preferred, forceReload: forceReload)
        kickOffEnrichmentIfMissing(latest)
    }

    /// Auto-enrich any Photo that became the active wallpaper without an
    /// enrichment yet. Hooked into every code path that "sees" a wallpaper
    /// — apply(), reapply(), syncWidgetFromCurrent's launch / focus / poll
    /// triggers — so the user never has to manually press ✨ for a photo
    /// the rotation engine never owned (e.g. a System Settings change to a
    /// previously-cached photo, or a freshly-launched app where rotation
    /// fired before enrichment plumbing existed).
    ///
    /// Idempotent. enrichIfNeeded short-circuits if `enrichment.enrichedAt`
    /// is set, and `enrichmentInFlight` serialises against concurrent calls
    /// — so the same photo can't trigger Ollama twice in parallel.
    private func kickOffEnrichmentIfMissing(_ photo: Photo) {
        if let existing = photo.enrichment, existing.enrichedAt != nil { return }
        Task { [weak self] in
            await self?.enrichIfNeeded(photo)
        }
    }

    /// Per-photo enrichment task. Two roles:
    ///   1. Dedup: if a photo is mid-enrichment (e.g. preCache kicked it off
    ///      and the user then rotates to it) the second call awaits the same
    ///      Task instead of starting a parallel Ollama run.
    ///   2. Serialisation: each new task chains off `lastEnrichmentTask`, so
    ///      Ollama only ever has one inference in flight — preventing the
    ///      32GB+ daemon blow-up we saw when concurrent /api/chat calls each
    ///      loaded a fresh model context.
    private var enrichmentTasks: [String: Task<Void, Never>] = [:]
    private var lastEnrichmentTask: Task<Void, Never>?

    func enrichIfNeeded(_ photo: Photo) async {
        if let existing = photo.enrichment, existing.enrichedAt != nil { return }
        let id = photo.unsplashID

        // Already running for this photo (e.g. preCache started it, user just
        // rotated to it) — join the existing task instead of duplicating work.
        if let inflight = enrichmentTasks[id] {
            log.info("enrichIfNeeded: joining in-flight enrichment for \(id, privacy: .public)")
            await inflight.value
            return
        }

        let prior = lastEnrichmentTask
        let task: Task<Void, Never> = Task { [weak self] in
            await prior?.value
            await self?.runEnrichment(photo)
        }
        enrichmentTasks[id] = task
        lastEnrichmentTask = task
        await task.value
        // Keep `lastEnrichmentTask` pointing at the latest launched task so
        // newcomers serialise behind it; just clear our per-photo slot.
        enrichmentTasks.removeValue(forKey: id)
    }

    /// User-initiated re-enrichment. Wipes the existing enrichment record so
    /// the next pass actually re-asks Ollama (enrichIfNeeded is otherwise a
    /// no-op on already-enriched photos).
    func regenerateEnrichment(for photo: Photo) async {
        isEnriching = true
        defer { isEnriching = false }
        if let existing = photo.enrichment {
            existing.enrichedAt = nil
            existing.buildingName = nil
            existing.architect = nil
            existing.year = nil
            existing.style = nil
            existing.oneSentence = nil
            existing.blurbShort = nil
            existing.blurbMedium = nil
            existing.blurbLong = nil
            try? Store.shared.context.save()
        }
        await enrichIfNeeded(photo)
    }

    /// Re-run enrichment on the most recently applied photo. Wired to the
    /// "Regenerate" button in the menu bar and the main-window toolbar.
    @discardableResult
    func regenerateMostRecent() async -> Bool {
        let descriptor = FetchDescriptor<Photo>(sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)])
        guard let latest = try? Store.shared.context.fetch(descriptor).first(where: { $0.lastSeenAt != nil }) else {
            return false
        }
        await regenerateEnrichment(for: latest)
        return true
    }

    private func runEnrichment(_ photo: Photo) async {
        if let existing = photo.enrichment, existing.enrichedAt != nil { return }

        let enrichment = photo.enrichment ?? {
            let e = Enrichment()
            e.photo = photo
            Store.shared.context.insert(e)
            return e
        }()

        // Pass the actual image file so the agent's vision model can SEE it.
        // ImageCache stores raw downloads at <id>.jpg; if it's missing the
        // agent still runs, just without vision.
        let imageURL: URL? = {
            let raw = ImageCache.shared.fileURL(for: photo.unsplashID)
            return FileManager.default.fileExists(atPath: raw.path) ? raw : nil
        }()

        // ArchitectureAgent: vision + MapKit + (optional) web_search agent
        // loop. Terminates when the model calls `commit_enrichment`.
        // Always tries to produce *some* useful caption (oneSentence) even
        // when no specific building is identified — that's how the widget
        // visibly updates after the async second pass even for generic photos.
        //
        // - If a building is confirmed (high/medium confidence): commit name,
        //   architect, year, style, and oneSentence. Confidence = .building.
        // - If only a sentence came back (low confidence): commit the sentence,
        //   leave architect/year/style blank, and store name as the area.
        //   Confidence = .areaOnly so widget knows building details aren't real.
        // - If the agent returned nil (Ollama unreachable / errored): leave
        //   every field blank.
        let confirmed = await ArchitectureAgent.confirm(for: photo, imageFileURL: imageURL)
        if let confirmed {
            let isBuilding = confirmed.architect != nil || confirmed.year != nil || confirmed.style != nil
            enrichment.buildingName = isBuilding ? confirmed.name : nil
            enrichment.architect = confirmed.architect
            enrichment.year = confirmed.year
            enrichment.style = confirmed.style
            enrichment.oneSentence = confirmed.oneSentence
            enrichment.blurbShort = confirmed.oneSentence
            enrichment.blurbMedium = confirmed.blurbMedium
            enrichment.blurbLong = confirmed.blurbLong
            enrichment.confidence = isBuilding ? .building : .areaOnly
            enrichment.modelUsed = UserDefaults.standard.string(forKey: "ollama.model")

            // Adopt the agent's specific location string when Unsplash gave
            // us only a country (or nothing). Stuff it into locationName so
            // the rest of the pipeline (bestPlaceTitle, widget area / footer)
            // picks it up automatically — no schema change needed. We only
            // overwrite blanks / single-component strings; if Unsplash already
            // returned a multi-comma "City, Country" we trust it.
            if let agentLoc = confirmed.location?.trimmingCharacters(in: .whitespacesAndNewlines), !agentLoc.isEmpty {
                let existing = (photo.locationName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let existingHasDetail = existing.contains(",")
                if !existingHasDetail {
                    photo.locationName = agentLoc
                }
            }
        } else {
            enrichment.buildingName = nil
            enrichment.architect = nil
            enrichment.year = nil
            enrichment.style = nil
            enrichment.oneSentence = nil
            enrichment.blurbShort = nil
            enrichment.blurbMedium = nil
            enrichment.blurbLong = nil
            enrichment.confidence = .areaOnly
        }
        enrichment.enrichedAt = .now
        try? Store.shared.context.save()
        log.info("enrichment ready for \(photo.unsplashID, privacy: .public) building=\(enrichment.buildingName ?? "-", privacy: .public) sentence=\(enrichment.oneSentence ?? "-", privacy: .public)")
        rewriteWidgetPayloadIfCurrent(photo, forceReload: true)
    }

    // MARK: - Private helpers

    private func ensureDownloaded(id: String, url: URL) async throws -> URL {
        let local = ImageCache.shared.fileURL(for: id)
        if FileManager.default.fileExists(atPath: local.path) { return local }
        let data = try await UnsplashService.shared.download(url)
        return try ImageCache.shared.put(data: data, for: id)
    }

    private func composeOverlayIfEnabled(for photo: Photo, sourceFile: URL) throws -> URL {
        let style = Store.shared.overlay()
        guard style.enabled else { return sourceFile }

        #if os(macOS)
        let output = ImageCache.shared.dir.appending(path: "\(photo.unsplashID).overlay.jpg")
        let text = OverlayRenderer.text(for: photo, style: style)
        try OverlayRenderer.compose(imageURL: sourceFile, text: text, style: style, to: output)
        return output
        #else
        return sourceFile
        #endif
    }

    /// Strip `com.apple.quarantine` from a file so a differently-sandboxed
    /// process (the widget extension) can read it.
    ///
    /// `removexattr()` fails with EPERM from inside the App Sandbox — we cannot
    /// manually launder quarantine off our own files. But `URLResourceKey.
    /// quarantinePropertiesKey` routes through LaunchServices and IS permitted
    /// from sandbox when we own the file. Set it to nil to clear.
    private func stripXattrsForWidget(_ url: URL) {
        var writable = url
        do {
            try (writable as NSURL).setResourceValue(NSNull(), forKey: .quarantinePropertiesKey)
        } catch {
            // Fallback via low-level xattr in case Launch Services isn't routing
            // the removal — usually logs EPERM which is expected in sandbox.
            let path = url.path
            for name in ["com.apple.quarantine", "com.apple.provenance"] {
                _ = path.withCString { cpath in
                    name.withCString { cname in
                        removexattr(cpath, cname, 0)
                    }
                }
            }
            log.error("quarantine clear via LS failed: \(error.localizedDescription, privacy: .public) on \(url.path, privacy: .public)")
        }
    }

    private func writeWidgetPayload(for photo: Photo, file: URL, forceReload: Bool = false) {
        let imageFileName = copyImageToAppGroup(from: file, photoID: photo.unsplashID)

        let payload = WidgetPayload(
            unsplashID: photo.unsplashID,
            imageFileName: imageFileName,
            buildingName: photo.enrichment?.buildingName,
            architect: photo.enrichment?.architect,
            year: photo.enrichment?.year,
            style: photo.enrichment?.style,
            oneSentence: photo.enrichment?.oneSentence,
            blurbShort: photo.enrichment?.blurbShort ?? photo.enrichment?.oneSentence,
            blurbMedium: photo.enrichment?.blurbMedium,
            blurbLong: photo.enrichment?.blurbLong,
            area: photo.areaText,
            authorName: photo.authorName,
            authorProfileURLString: photo.authorProfileURLString,
            cameraLine: photo.exif?.cameraLine.isEmpty == false ? photo.exif?.cameraLine : nil,
            lensLine: photo.exif?.lensLine.isEmpty == false ? photo.exif?.lensLine : nil,
            shotLine: photo.exif?.shotLine.isEmpty == false ? photo.exif?.shotLine : nil,
            latitude: photo.exif?.latitude,
            longitude: photo.exif?.longitude,
            takenAtSeconds: photo.exif?.takenAt?.timeIntervalSince1970,
            updatedAtSeconds: Date.now.timeIntervalSince1970,
            photoDescription: photo.photoDescription,
            altDescription: photo.altDescription,
            locationName: photo.locationName,
            locationCity: photo.locationCity,
            locationCountry: photo.locationCountry,
            tags: photo.tags.isEmpty ? nil : photo.tags,
            hexColor: photo.hexColor
        )
        commitPayload(payload, contextLabel: "photo \(photo.unsplashID)", forceReload: forceReload)
    }

    /// Writes a payload for an image we don't own (user picked it in System
    /// Settings, etc.) — no enrichment, just the raw photo file.
    ///
    /// macOS supplies its built-in wallpapers from sandbox-protected
    /// locations (e.g. `~/Library/Application Support/com.apple.ScreenContinuity/`)
    /// that our App Sandbox can't read. When the source is unreadable we skip
    /// the write entirely so we don't overwrite a good payload with a blank
    /// one — the widget keeps showing the last real photo.
    private func writeExternalPayload(file: URL, forceReload: Bool = false) {
        let id = "external-\(file.lastPathComponent)"
        let imageFileName = copyImageToAppGroup(from: file, photoID: id)
        if imageFileName.isEmpty {
            log.info("writeExternalPayload: skipping — could not copy \(file.path, privacy: .public)")
            return
        }
        let payload = WidgetPayload(
            unsplashID: id,
            imageFileName: imageFileName,
            buildingName: nil,
            architect: nil,
            year: nil,
            style: nil,
            oneSentence: nil,
            blurbShort: nil,
            blurbMedium: nil,
            blurbLong: nil,
            area: file.deletingPathExtension().lastPathComponent,
            authorName: "",
            authorProfileURLString: nil,
            cameraLine: nil,
            lensLine: nil,
            shotLine: nil,
            latitude: nil,
            longitude: nil,
            takenAtSeconds: nil,
            updatedAtSeconds: Date.now.timeIntervalSince1970,
            photoDescription: nil,
            altDescription: nil,
            locationName: nil,
            locationCity: nil,
            locationCountry: nil,
            tags: nil,
            hexColor: nil
        )
        commitPayload(payload, contextLabel: "external \(file.lastPathComponent)", forceReload: forceReload)
    }

    /// Persists `payload` to the App Group and reloads widget timelines.
    ///
    /// Normally we skip the write+reload when the payload is byte-identical to
    /// what's already on disk — that lets the 30s `WallpaperWatcher` tick run
    /// silently. Pass `forceReload: true` to bypass that check; the async
    /// architecture-agent second pass uses this so the widget visibly refreshes
    /// even when the agent produced no new text (e.g. low-confidence skip).
    private func commitPayload(_ payload: WidgetPayload, contextLabel: String, forceReload: Bool = false) {
        let unchanged = payloadIsUnchanged(payload)
        if unchanged && !forceReload {
            return
        }
        if !unchanged {
            do {
                try payload.write()
                stripXattrsForWidget(WidgetPayload.payloadFileURL())
                log.info("wrote widget payload \(contextLabel, privacy: .public) image=\(payload.imageFileName, privacy: .public) title=\(payload.buildingName ?? payload.photoDescription ?? payload.area, privacy: .public)")
            } catch {
                log.error("payload.write failed: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            log.info("payload unchanged for \(contextLabel, privacy: .public) — forcing widget reload only")
        }

        #if canImport(WidgetKit)
        // reloadAllTimelines is documented to cover every kind, but on
        // macOS 26 chronod has been observed to drop reloads (see Stats #2733,
        // FB11522170). Calling per-kind as well is a cheap belt-and-suspenders.
        WidgetCenter.shared.reloadAllTimelines()
        for kind in ["paperpaper.photo", "paperpaper.card", "paperpaper.clear"] {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
        #endif
    }

    /// Compare semantically — `updatedAtSeconds` is excluded so a no-op tick
    /// doesn't look "new".
    private func payloadIsUnchanged(_ candidate: WidgetPayload) -> Bool {
        guard let existing = WidgetPayload.read() else { return false }
        return existing.unsplashID == candidate.unsplashID
            && existing.imageFileName == candidate.imageFileName
            && existing.buildingName == candidate.buildingName
            && existing.architect == candidate.architect
            && existing.year == candidate.year
            && existing.style == candidate.style
            && existing.oneSentence == candidate.oneSentence
            && existing.blurbShort == candidate.blurbShort
            && existing.blurbMedium == candidate.blurbMedium
            && existing.blurbLong == candidate.blurbLong
            && existing.area == candidate.area
            && existing.authorName == candidate.authorName
            && existing.authorProfileURLString == candidate.authorProfileURLString
            && existing.cameraLine == candidate.cameraLine
            && existing.lensLine == candidate.lensLine
            && existing.shotLine == candidate.shotLine
            && existing.locationName == candidate.locationName
            && existing.locationCity == candidate.locationCity
            && existing.locationCountry == candidate.locationCountry
            && existing.photoDescription == candidate.photoDescription
            && existing.altDescription == candidate.altDescription
            && existing.latitude == candidate.latitude
            && existing.longitude == candidate.longitude
            && existing.takenAtSeconds == candidate.takenAtSeconds
    }

    /// Try to map a desktop wallpaper URL back to one of our known Photos.
    /// Filenames in `ImageCache` are `<unsplashID>.jpg` and overlays are
    /// `<unsplashID>.overlay.jpg`.
    private func matchPhoto(for url: URL) -> Photo? {
        var name = url.deletingPathExtension().lastPathComponent
        if name.hasSuffix(".overlay") { name = String(name.dropLast(".overlay".count)) }
        guard !name.isEmpty else { return nil }

        var descriptor = FetchDescriptor<Photo>(predicate: #Predicate { $0.unsplashID == name })
        descriptor.fetchLimit = 1
        return try? Store.shared.context.fetch(descriptor).first
    }

    /// "External" = not inside our ImageCache directory.
    private func isExternal(_ url: URL) -> Bool {
        !url.path.hasPrefix(ImageCache.shared.dir.path)
    }

    private func copyImageToAppGroup(from sourceFile: URL, photoID: String) -> String {
        let fm = FileManager.default
        let dir = WidgetPayload.widgetDir()
        let name = "current.jpg"
        let destination = dir.appending(path: name)
        if !fm.fileExists(atPath: sourceFile.path) {
            log.error("copy source missing: \(sourceFile.path, privacy: .public)")
            return ""
        }
        // ROOT CAUSE of recurring "you don't have permission to access widget"
        // errors: Xcode debug builds inherit `com.apple.quarantine` xattr on
        // every file/dir they write, including into the App Group container.
        // The App Sandbox refuses copyItem into a quarantined directory. We
        // strip both xattrs from the directory before every write so the
        // failure can't compound across builds.
        stripXattrsForWidget(dir)

        if !ensureWritableDir(dir) {
            log.error("widget dir not writable, attempting recreate: \(dir.path, privacy: .public)")
            try? fm.removeItem(at: dir)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            stripXattrsForWidget(dir)
            if !ensureWritableDir(dir) {
                log.error("widget dir still not writable after recreate — App Group entitlement misconfigured? \(dir.path, privacy: .public)")
                return ""
            }
        }
        _ = try? fm.removeItem(at: destination)
        do {
            try fm.copyItem(at: sourceFile, to: destination)
            stripXattrsForWidget(destination)
            return name
        } catch {
            let ns = error as NSError
            log.error("copy to app group failed: \(error.localizedDescription, privacy: .public) [\(ns.domain, privacy: .public) \(ns.code, privacy: .public)] src=\(sourceFile.path, privacy: .public) dest=\(destination.path, privacy: .public)")
            return ""
        }
    }

    private func ensureWritableDir(_ dir: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        return fm.isWritableFile(atPath: dir.path)
    }

    private func rewriteWidgetPayloadIfCurrent(_ photo: Photo, forceReload: Bool = false) {
        let descriptor = FetchDescriptor<Photo>(sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)])
        guard let latest = try? Store.shared.context.fetch(descriptor).first(where: { $0.lastSeenAt != nil }),
              latest.unsplashID == photo.unsplashID else { return }

        let style = Store.shared.overlay()
        let raw = ImageCache.shared.fileURL(for: photo.unsplashID)
        let overlay = ImageCache.shared.dir.appending(path: "\(photo.unsplashID).overlay.jpg")
        let preferred: URL = {
            if style.enabled, FileManager.default.fileExists(atPath: overlay.path) { return overlay }
            return raw
        }()
        writeWidgetPayload(for: photo, file: preferred, forceReload: forceReload)
    }

    private func enforceCacheCap() {
        let maxMB = UserDefaults.standard.object(forKey: "cache.maxSizeMB") as? Double ?? 500
        let maxBytes = Int64(maxMB * 1024 * 1024)
        let protected = currentWallpaperIDs()
        ImageCache.shared.enforceCap(maxBytes: maxBytes, protectedIDs: protected)
    }

    private func currentWallpaperIDs() -> Set<String> {
        let descriptor = FetchDescriptor<Photo>(sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)])
        guard let recent = try? Store.shared.context.fetch(descriptor).prefix(3) else { return [] }
        return Set(recent.map(\.unsplashID))
    }
}
