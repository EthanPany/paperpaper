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
    /// Surfaced in Connections so users can see the most recent enrichment
    /// outcome without opening Console.app. Updated at the tail of every
    /// runEnrichment call.
    var lastEnrichmentStatus: String?
    var lastEnrichmentAt: Date?

    /// Whether the selected model provider has what it needs to attempt AI
    /// enrichment. Ollama is local best-effort (always "configured"); a Cloud
    /// API needs an API key. Used by the rotation engine to label the last
    /// trigger as "AI text pending" vs "AI text off".
    var isEnrichmentConfigured: Bool {
        switch AIProvider.current {
        case .ollama: return true
        case .openAICompatible:
            return (KeychainService.shared.get(.openAIAPIKey)?.isEmpty == false)
        }
    }

    @ObservationIgnored
    private let log = Logger(subsystem: "me.ethanpan.paperpaper", category: "widget-sync")

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
        try WallpaperService.shared.setOnAllScreens(imageURL: rawFile)
        // Cross-Space propagation: SpaceObserver (started from app init)
        // calls reapplyOnCurrentSpace() on every active-space change, so
        // this rotation will land on each Space the user visits — no per-
        // apply TTL observer needed.
        #endif

        // Mark "shown" only after the wallpaper actually set. Recording before
        // would burn the photo into the no-repeats cooldown even when
        // setOnAllScreens throws and the user never sees it.
        Store.shared.recordShown(photo)

        writeWidgetPayload(for: photo, file: rawFile)

        // Broadcast to other iCloud devices when this Mac is the primary.
        // Coordinator no-ops if sync is disabled or another Mac is primary.
        iCloudSyncCoordinator.shared.publishPhotoApplied(unsplashID: photo.unsplashID)

        // Unsplash API TOS: hit `links.download_location` whenever we trigger
        // a download (applying as wallpaper qualifies). Fire-and-forget; a
        // network blip here mustn't block the apply.
        Task { await UnsplashService.shared.trackDownload(unsplash) }

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

        Store.shared.recordShown(photo)

        // See apply(unsplash:) — wallpaper first, then widget, with the
        // watcher gate held shut for the duration so a concurrent space-
        // change or 30s-tick can't snapshot a half-applied state.
        suppressWatcherSync = true
        defer { suppressWatcherSync = false }

        #if os(macOS)
        try WallpaperService.shared.setOnAllScreens(imageURL: rawFile)
        // Cross-Space propagation is handled by the always-on SpaceObserver
        // installed in paperpaperApp.init — it calls reapplyOnCurrentSpace()
        // every time the user switches Spaces, with no TTL.
        #endif

        // forceReload=true: the user asked for this explicitly, so refresh
        // the widget timeline even if the payload bytes are unchanged. The
        // most common reason fields differ at this point is that an async
        // enrichment landed AFTER the last automatic write — without
        // forceReload, the widget would keep rendering the pre-enrichment
        // payload.
        writeWidgetPayload(for: photo, file: rawFile, forceReload: true)

        // Reapplied photo might be one the rotation engine never enriched
        // (e.g. user picked it manually from Discover). Kick off the agent
        // so the widget gets caught up — no-op when already enriched.
        kickOffEnrichmentIfMissing(photo)

        enforceCacheCap()
        return true
    }

    /// Re-set the macOS wallpaper on the *current* Space using the most-
    /// recently applied photo's cached file. macOS only sets wallpaper on
    /// the active Space, so a single rotation otherwise stays on whichever
    /// Space was active when it fired. SpaceObserver (started from
    /// paperpaperApp.init) calls this on every active-space change.
    ///
    /// Lightweight: no download, no widget rewrite, no enrichment. Gated on
    /// `spaceMode == .unified` — that's the only mode that semantically
    /// asks for one wallpaper across every Space.
    func reapplyOnCurrentSpace() async {
        let rule = Store.shared.rule()
        guard rule.spaceMode == .unified else {
            log.info("space-change reapply: skipped (spaceMode=\(rule.spaceMode.rawValue, privacy: .public), not unified)")
            return
        }

        let descriptor = FetchDescriptor<Photo>(sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)])
        guard let latest = try? Store.shared.context.fetch(descriptor).first(where: { $0.lastSeenAt != nil }) else {
            log.info("space-change reapply: skipped (no applied photo on file yet)")
            return
        }
        let raw = ImageCache.shared.fileURL(for: latest.unsplashID)
        guard FileManager.default.fileExists(atPath: raw.path) else {
            log.info("space-change reapply: skipped (cached file missing for \(latest.unsplashID, privacy: .public))")
            return
        }

        #if os(macOS)
        // Hold the watcher gate so a concurrent WallpaperWatcher tick can't
        // snapshot a half-applied state during the set.
        suppressWatcherSync = true
        defer { suppressWatcherSync = false }
        do {
            // Idempotent: only screens NOT already showing this image get
            // re-set. Revisiting a Space we've already pushed to does zero work
            // — no flash, no Dock churn — so the common case feels as quick as
            // the old single-set behavior. Only a Space that genuinely lacks
            // the wallpaper pays the one-time legacy-API set.
            let changed = try WallpaperService.shared.reapplyOnAllScreensIfNeeded(imageURL: raw)
            log.info("space-change reapply: \(changed ? "set" : "already-current", privacy: .public) for \(latest.unsplashID, privacy: .public)")
        } catch {
            log.error("space-change reapply failed: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

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

        // Pre-fetching can grow the folder past the cap; trim it here too so
        // prefetch doesn't quietly defeat "keep only references". Only image
        // bytes are dropped — never the metadata we just upserted.
        enforceCacheCap()
    }

    /// Dumps the current on-disk widget payload field-by-field to the unified
    /// log. Hooked to a "Refresh widget" menu-bar button. Use Console.app with
    /// `subsystem:me.ethanpan.paperpaper category:widget-sync` to inspect — this is the
    /// fastest way to disambiguate "WidgetKit isn't refreshing" from "the
    /// payload is empty so there's nothing to render."
    func logWidgetPayloadForDiagnostics() {
        guard let payload = WidgetPayload.read() else {
            log.error("DIAG: WidgetPayload.read() returned nil — App Group unreachable or never written")
            return
        }
        log.info("DIAG payload id=\(payload.unsplashID, privacy: .public) image=\(payload.imageFileName, privacy: .public)")
        log.info("DIAG title-chain building=\(payload.buildingName ?? "-", privacy: .public) photoDesc=\(payload.photoDescription ?? "-", privacy: .public) alt=\(payload.altDescription ?? "-", privacy: .public) area=\(payload.area, privacy: .public) loc=\(payload.locationName ?? "-", privacy: .public)")
        log.info("DIAG enrichment building=\(payload.buildingName ?? "-", privacy: .public) short=\(payload.blurbShort ?? payload.oneSentence ?? "-", privacy: .public)")
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
        log.info("syncWidgetFromCurrent: desktopURL=\(desktopURL?.lastPathComponent ?? "nil", privacy: .public) forceReload=\(forceReload, privacy: .public)")
        if let url = desktopURL, let photo = matchPhoto(for: url) {
            // Fast path: when the payload already describes this exact photo and
            // nobody asked for a forced reload, skip writeWidgetPayload entirely.
            // That method re-copies current.jpg into the App Group on the main
            // actor (disk I/O) BEFORE commitPayload even gets to decide it's
            // unchanged — so without this guard every space-change tick / 30s
            // tick re-copies a multi-MB file for nothing, stacking onto the
            // legacy-set hitch on a Space switch. matchPhoto already proved it's
            // our image, so an unchanged unsplashID means the widget is current.
            if !forceReload, WidgetPayload.read()?.unsplashID == photo.unsplashID {
                log.info("syncWidgetFromCurrent: payload already current for \(photo.unsplashID, privacy: .public) — skip copy/reload")
                kickOffEnrichmentIfMissing(photo)
                return
            }
            log.info("syncWidgetFromCurrent: matched our photo \(photo.unsplashID, privacy: .public)")
            writeWidgetPayload(for: photo, file: url, forceReload: forceReload)
            kickOffEnrichmentIfMissing(photo)
            return
        }
        if let url = desktopURL {
            // A macOS *system/default* wallpaper (DefaultDesktop.heic, a Dynamic
            // wallpaper, the ScreenContinuity hand-off image) is NOT a deliberate
            // user choice. It's the transient frame macOS shows on a Space we
            // haven't pushed our image to yet, or for the split-second while
            // WallpaperAgent tears a Dynamic wallpaper down to swap in a still.
            // The space observer's reapply re-pushes our image moments later, so
            // recording this frame would only clobber the good photo card with a
            // blank "DefaultDesktop" payload — the exact "widget shows nothing /
            // shows the default" failure. Leave the last real payload intact and
            // let the next (post-reapply) sync match our photo.
            if isSystemWallpaper(url) {
                log.info("syncWidgetFromCurrent: ignoring system/default wallpaper \(url.lastPathComponent, privacy: .public) — keeping last payload")
                return
            }
            if isExternal(url) {
                log.info("syncWidgetFromCurrent: external user wallpaper \(url.lastPathComponent, privacy: .public)")
                writeExternalPayload(file: url, forceReload: forceReload)
                return
            }
        }
        #endif

        // Fall back to most recent applied photo (case 2 / non-macOS).
        let descriptor = FetchDescriptor<Photo>(sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)])
        guard let latest = try? Store.shared.context.fetch(descriptor).first(where: { $0.lastSeenAt != nil }) else {
            log.info("syncWidgetFromCurrent: no applied photo yet, no desktop URL")
            return
        }
        let raw = ImageCache.shared.fileURL(for: latest.unsplashID)
        writeWidgetPayload(for: latest, file: raw, forceReload: forceReload)
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

    /// `searchQuery` / `searchWasLocationBiased` carry the rotation's search
    /// provenance into the agent so it can tell a worldwide-fallback photo from
    /// a location-biased one. Optional — callers that didn't run a search
    /// (manual regenerate, syncWidgetFromCurrent) pass nil and the agent simply
    /// gets no provenance hint.
    func enrichIfNeeded(_ photo: Photo, searchQuery: String? = nil, searchWasLocationBiased: Bool = false) async {
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
            await self?.runEnrichment(photo, searchQuery: searchQuery, searchWasLocationBiased: searchWasLocationBiased)
        }
        enrichmentTasks[id] = task
        // isEnriching tracks ANY in-flight enrichment, regardless of who
        // triggered it. Auto-runs from preCache or rotation flip the same
        // flag the regenerate button reads, so the UI shows a spinner during
        // background work — no separate "is auto-running" state needed.
        isEnriching = true
        lastEnrichmentTask = task
        await task.value
        enrichmentTasks.removeValue(forKey: id)
        isEnriching = !enrichmentTasks.isEmpty
    }

    /// User-initiated re-enrichment. Wipes the existing enrichment record so
    /// the next pass actually re-asks Ollama (enrichIfNeeded is otherwise a
    /// no-op on already-enriched photos).
    func regenerateEnrichment(for photo: Photo) async {
        // isEnriching is owned by enrichIfNeeded now — it sets/clears
        // the flag whenever any task is in flight, regardless of trigger.
        if let existing = photo.enrichment {
            existing.enrichedAt = nil
            existing.buildingName = nil
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

    private func runEnrichment(_ photo: Photo, searchQuery: String? = nil, searchWasLocationBiased: Bool = false) async {
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
        let confirmed = await ArchitectureAgent.confirm(
            for: photo,
            imageFileURL: imageURL,
            searchQuery: searchQuery,
            searchWasLocationBiased: searchWasLocationBiased
        )
        // Only mark enrichedAt when the agent actually produced something
        // usable. A failed run (nil, or empty blurbs) leaves enrichedAt nil
        // so the next `enrichIfNeeded` call — from preCache on the next app
        // open, or from `kickOffEnrichmentIfMissing` when the user rotates
        // back to this photo — re-runs the agent. Overlap is fine; the
        // per-photo `enrichmentTasks` dict deduplicates concurrent calls.
        let succeeded = (confirmed?.oneSentence?.isEmpty == false)
            || (confirmed?.blurbMedium?.isEmpty == false)
            || (confirmed?.blurbLong?.isEmpty == false)
        if let confirmed {
            // Keep the building name whenever the agent committed a real
            // (non-placeholder) name. makeConfirmed assigns "—" when it had
            // no name, so that's the only case we drop.
            let trimmedName = confirmed.name.trimmingCharacters(in: .whitespaces)
            let hasName = trimmedName != "—" && !trimmedName.isEmpty
            enrichment.buildingName = hasName ? confirmed.name : nil
            enrichment.oneSentence = confirmed.oneSentence
            enrichment.blurbShort = confirmed.oneSentence
            enrichment.blurbMedium = confirmed.blurbMedium
            enrichment.blurbLong = confirmed.blurbLong
            enrichment.modelUsed = AIProvider.current == .openAICompatible
                ? UserDefaults.standard.string(forKey: AIProvider.Keys.openAIModel)
                : UserDefaults.standard.string(forKey: "ollama.model")

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
            enrichment.oneSentence = nil
            enrichment.blurbShort = nil
            enrichment.blurbMedium = nil
            enrichment.blurbLong = nil
        }
        if succeeded {
            enrichment.enrichedAt = .now
        }
        try? Store.shared.context.save()
        log.info("enrichment \(succeeded ? "ready" : "deferred (no commit, will retry)", privacy: .public) for \(photo.unsplashID, privacy: .public) building=\(enrichment.buildingName ?? "-", privacy: .public) sentence=\(enrichment.oneSentence ?? "-", privacy: .public)")

        // Surface a one-liner in the Connections tab so users don't have to
        // open Console.app to know whether the agent succeeded.
        if succeeded, let confirmed {
            let label = enrichment.buildingName ?? confirmed.name
            lastEnrichmentStatus = "Succeeded — \(label)"
        } else {
            lastEnrichmentStatus = "No commit — will retry on next view"
        }
        lastEnrichmentAt = .now

        rewriteWidgetPayloadIfCurrent(photo, forceReload: true)
    }

    // MARK: - Private helpers

    private func ensureDownloaded(id: String, url: URL) async throws -> URL {
        let local = ImageCache.shared.fileURL(for: id)
        // Cache hit: reuse the bytes already on disk. After a cap eviction the
        // file may be gone even though the Photo row still exists — we just
        // re-download it here. The enrichment is keyed off the Photo, so it is
        // never recomputed; this is the "keep metadata, re-fetch bytes" path.
        if FileManager.default.fileExists(atPath: local.path) { return local }
        let data = try await UnsplashService.shared.download(url)
        return try ImageCache.shared.put(data: data, for: id)
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
    /// Filenames in `ImageCache` are `<unsplashID>.jpg`.
    private func matchPhoto(for url: URL) -> Photo? {
        let name = url.deletingPathExtension().lastPathComponent
        guard !name.isEmpty else { return nil }

        var descriptor = FetchDescriptor<Photo>(predicate: #Predicate { $0.unsplashID == name })
        descriptor.fetchLimit = 1
        return try? Store.shared.context.fetch(descriptor).first
    }

    /// "External" = not inside our ImageCache directory.
    private func isExternal(_ url: URL) -> Bool {
        !url.path.hasPrefix(ImageCache.shared.dir.path)
    }

    /// macOS system / default wallpapers — the frames the OS shows transiently
    /// on a Space we haven't pushed our image to, or while a Dynamic wallpaper
    /// rebuilds. These are NOT user choices and must never be recorded into the
    /// widget payload (doing so overwrites the real photo card with a blank
    /// "DefaultDesktop" one). Distinct from `isExternal`, which also covers a
    /// genuine user-picked image in ~/Pictures that we *do* want to mirror.
    private func isSystemWallpaper(_ url: URL) -> Bool {
        let path = url.path
        if url.lastPathComponent == "DefaultDesktop.heic" { return true }
        if path.hasPrefix("/System/") { return true }
        if path.contains("/Library/Desktop Pictures/") { return true }
        if path.contains("com.apple.ScreenContinuity") { return true }
        if path.contains("com.apple.wallpaper") { return true }
        return false
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
        // Bundle ID changes in DEBUG (we ship as me.ethanpan.paperpaper right now)
        // leave images in older sandbox containers (e.g. ~/Library/Containers/
        // me.ethanpan.paperpaper/...) that the current sandbox can't read. Detect that
        // up front so we don't fall through to a copyItem failure that floods
        // the log on every WallpaperWatcher tick.
        if !fm.isReadableFile(atPath: sourceFile.path) {
            log.info("copy source not readable from this sandbox (likely stale container): \(sourceFile.path, privacy: .public)")
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

        let raw = ImageCache.shared.fileURL(for: photo.unsplashID)
        writeWidgetPayload(for: photo, file: raw, forceReload: forceReload)
    }

    /// Default ceiling on cached image FILES. With "no repeats" on, every
    /// rotation downloads a fresh photo, so a large cache buys nothing for
    /// variety — its only real value is a handful of recent images to fall back
    /// on when you're offline. 24 keeps that bounded so the folder never grows
    /// large; the Photo/Enrichment rows live in SwiftData regardless, so a
    /// re-encountered photo is just re-downloaded, never re-described.
    static let defaultMaxCachedImages = 24

    private func enforceCacheCap() {
        // Keep at most N image files — the newest — on disk. The current
        // wallpaper(s) and any prefetched-but-unshown photos are always
        // protected from eviction.
        let maxImages = UserDefaults.standard.object(forKey: "cache.maxImages") as? Int ?? Self.defaultMaxCachedImages
        var protected = currentWallpaperIDs()
        // Prefetch warms the next N photos before they're shown, so they have
        // no lastSeenAt and miss the "recently shown" set. Protect the N
        // most-recently-cached files too so a freshly-warmed photo isn't
        // evicted the instant it lands.
        let prefetchCount = UserDefaults.standard.object(forKey: "cache.prefetchCount") as? Int ?? 0
        if prefetchCount > 0 {
            protected.formUnion(ImageCache.shared.recentlyCachedIDs(limit: prefetchCount))
        }
        let removed = ImageCache.shared.enforceCount(maxCount: maxImages, protectedIDs: protected)
        if removed > 0 {
            log.info("cache trim: removed \(removed, privacy: .public) old image(s), keeping newest \(maxImages, privacy: .public) (+\(protected.count, privacy: .public) protected)")
        }
    }

    private func currentWallpaperIDs() -> Set<String> {
        let descriptor = FetchDescriptor<Photo>(sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)])
        guard let recent = try? Store.shared.context.fetch(descriptor).prefix(3) else { return [] }
        return Set(recent.map(\.unsplashID))
    }
}
