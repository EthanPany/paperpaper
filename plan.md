# paperpaper — Plan

A macOS wallpaper app made for people who love architecture and photography. Photos come from Unsplash. A local Ollama model adds a name and one-sentence blurb when a building is clearly identified. Full EXIF, GPS, and location text are stored and shown. Everything runs on the user's machine. Optional iCloud sync across their devices. No backend from us.

---

## 1. Overall Goals

- **Primary:** Rotate the Mac desktop wallpaper on a schedule with beautiful architecture photos, tell the user what they are looking at when possible, and surface the kind of camera/EXIF detail that photographers actually care about.
- **Voice:** Built from a photographer's point of view. Credit is visible, EXIF is first-class, author attribution is never hidden.
- **Feel:** Native, quiet, fast. Menu bar app runs in the background by default. Liquid Glass look on macOS 26.
- **Architecture-first, but modular:** The image source, the metadata enricher, and the rotation engine are separate pieces. Swapping "architecture" for "mountains" or "interiors" later is a config change, not a rewrite.
- **Local and private:** All keys, history, cache, and model calls stay on the device. Optional iCloud sync between the user's own devices. No analytics, no third-party server from us.
- **Settings-heavy for v1:** Because we are still testing, expose almost every knob — cache sizes, pre-fetch count, intervals in seconds, timeouts, retry counts, Ollama model params, logging level.
- **Low footprint:** Small memory use, no background CPU spikes, battery-aware, respectful of network.
- **Multi-display and multi-Space aware:** Works on laptops, multi-monitor setups, and across macOS Spaces, handling the known OS limits honestly.

Non-goals for v1:
- No own backend.
- No social features, no account system of our own.
- No heavy in-app photo editing beyond fit, crop, and the burn-in text overlay.

---

## 2. UI / UX Design

### Shape of the app
- **Menu bar item (always on).** The app lives in the menu bar. Closing the main window does not quit the app; it keeps rotating. Quit is explicit. The icon has a small status dot (green / yellow / red / gray).
- **Menu bar popover** — Next, Previous, Pause, Open Library, Open Settings, a tiny thumbnail of the current wallpaper, building name (or area), EXIF one-liner (camera + aperture), author credit.
- **Main window** opens from the menu bar. SwiftUI `TabView` with Liquid Glass:

  1. **Now** — the current wallpaper, big. Shows: name / architect / blurb (if known), area text, full EXIF block (camera, lens, focal length, aperture, shutter, ISO, taken-at), GPS if present (as "41.40°N, 2.17°E" text), author with link to their Unsplash profile, Unsplash license line. Quick actions: Next, Keep, Favorite, Hide, Download, Open on Unsplash.
  2. **Library** — grid of everything shown, lazy-loaded thumbnails. Filters: favorites, has-building, by country, by camera, by lens. Detail view includes full EXIF.
  3. **Discover** — browse Unsplash topics/tags within the architecture focus, add topics to the rotation pool, preview a shuffle. Also a "By photographer" search.
  4. **Rotation** — interval (down to seconds for testing), day/night schedule, per-display rules, Space behavior, filters (color, aspect ratio, camera, focal length, country), separate dark/light pools.
  5. **Overlay** — optional burn-in text. Live, debounced preview. Font, size, color, corner, margin, drop shadow. Option to show EXIF line instead of blurb.
  6. **Cache** — size, hit rate, pre-fetch count, TTLs, per-cache clear buttons, "keep only references" toggle.
  7. **Sync** — enable iCloud sync, pick what syncs (settings / history / favorites / keys), status, last-sync timestamp, force-sync button.
  8. **Connections** — Unsplash API key, Ollama URL + model + params (temperature, timeout, web-search toggle), test buttons.
  9. **Advanced** — logging level, network timeouts, retry counts, reset all, export diagnostic bundle. Hidden behind a small toggle for non-testing builds later.

### Photographer perspective, concretely
- EXIF block is not an afterthought. It has its own well-typed section on the Now tab and in widget layout option.
- Author name appears on every screen that shows a photo, with a link to the photographer's Unsplash profile.
- Filters include camera body, lens, and focal length range.
- Favorites export bundles the image with an XMP sidecar containing the original EXIF, author, and Unsplash attribution.

### Core interactions
- Every setting has an immediate preview when it can. No "Save" buttons — changes commit live, with an undo toast on destructive actions.
- Library grid uses Unsplash `thumb` size for thumbnails; full bytes only load on detail.
- Overlay preview debounces at roughly 120 ms; the real composite renders once on release or commit.
- Network and model health show as the menu bar dot: green (healthy), yellow (slow or partial), red (failing), gray (offline / paused).

### Visual style
- SwiftUI, macOS 26 Liquid Glass materials.
- Native macOS chrome. No custom window chrome.
- Accent follows system accent; dark and light mode both fully supported.

---

## 3. Data Pipeline

### Sources
- **Unsplash** (user's own API key in Connections).
- **Ollama**, running locally. User supplies URL, model, and optional auth header.

### Flow for one wallpaper
1. **Pick a candidate.**
   - Query Unsplash using the user's selected topics/tags.
   - Filter out photos already shown (by Unsplash photo id) unless the user allowed repeats.
   - Apply filters: orientation, color, aspect ratio, camera, focal length, country (if user set them).
2. **Fetch and parse.**
   - Download the size that fits the largest target display.
   - Parse EXIF from the downloaded bytes using `ImageIO` + `CGImageSource`. Extract camera, lens, focal length, aperture, shutter, ISO, taken-at, GPS lat/long, color profile, orientation.
   - Also read Unsplash's provided location text (`location.city`, `location.country`, `location.name`). This is usually vague (city or country), which is what we want.
3. **Cache bytes.** Temp cache directory. LRU, size-capped. Full image bytes are ephemeral; references are forever.
4. **Enrich.**
   - Run `BuildingDetector` on `description + alt_description + tags + location.name`:
     - Drop generic tokens (`architecture`, `building`, `city`, `urban`, `skyline`, `cityscape`, `modern`, etc.).
     - Prefer capitalized multi-word phrases and known-landmark seed matches.
     - If GPS is present, include it as a hint to Ollama (but do not blindly trust it — it can be the photographer's position, not the subject's).
   - If a candidate name survives, call Ollama with strict JSON schema `{name, architect_or_null, year_or_null, style_or_null, one_sentence}` and a "say unknown if not sure" instruction.
   - Parse JSON. Drop malformed responses. Cache result keyed by Unsplash photo id forever.
   - If no candidate survives, confidence = `area-only`; skip Ollama.
5. **Apply.**
   - Set wallpaper per `NSScreen` via `NSWorkspace.setDesktopImageURL`.
   - If overlay is on, render a composite first (Core Image) and apply that.
   - Write `WidgetPayload` JSON to the App Group and reload widget timelines.
6. **Pre-cache.**
   - Pre-fetch and pre-enrich the next N candidates (user-configurable, default 3). Makes rotation instant and offline-friendly.

### Spaces awareness (macOS)
- macOS has multiple Spaces per display. Each Space can hold its own desktop picture.
- Public API limits: `NSWorkspace.setDesktopImageURL(_:for:options:)` sets the wallpaper for the **currently active** Space on the given `NSScreen`. There is no public API to target a specific non-active Space directly.
- Our approach for v1:
  - Observe `NSWorkspace.activeSpaceDidChangeNotification`.
  - Maintain per-Space rotation state keyed by a local Space identifier derived from the notification order (ephemeral; lost on restart — that is an OS constraint, we document it).
  - Let the user pick one of three modes in Rotation → Spaces:
    1. **Unified** — same rotation everywhere. Rotate only when the current Space is focused; on Space switch, bring that Space to the latest wallpaper.
    2. **Per-Space independent** — each visited Space gets its own rotation state. When the user visits a Space, the app applies that Space's next wallpaper.
    3. **Active-only** — rotate only on the active Space, leave others alone.
- This is an honest treatment of the constraint, not a claim that we can set wallpaper on hidden Spaces silently.

### What gets stored
- **Long-term (SwiftData, device + optional iCloud):**
  - Photo record: Unsplash id, URLs for `thumb`/`regular`/`full`/`raw`, author and profile URL, description, alt_description, tags, Unsplash location text (city, country, name), width, height, color.
  - EXIF record (belongs to photo): camera make/model, lens, focal length, aperture, shutter, ISO, taken-at, GPS lat/long, color profile, orientation.
  - Enrichment record (belongs to photo): detected name, architect, year, style, one_sentence, confidence tier, enriched-at timestamp, model name used.
  - RotationRule, Filter, OverlayStyle, Favorites, History events.
- **Short-term (disk cache, device only, never synced):** image bytes under the user's size cap.
- **Keychain:** Unsplash key, optional Ollama auth. Marked `kSecAttrSynchronizable` only if the user turns on "sync keys."

### iCloud sync
- Uses SwiftData's CloudKit integration (`isStoredInMemoryOnly: false`, CloudKit-backed store).
- Four sync scopes, each separately toggleable by the user in the Sync tab:
  1. Settings (rotation rules, filters, overlay style, Connections UI prefs, cache prefs).
  2. History and favorites.
  3. Enrichment cache (saves re-querying Ollama on other devices).
  4. API keys (Keychain items with `kSecAttrSynchronizable`).
- Never synced: image bytes, current-wallpaper state (per-device), Space identifiers.
- The Sync tab shows what is syncing, last push / pull timestamps, conflict count, and a "Replace remote with this device" escape hatch.

---

## 4. Code Logic

### Layers
- **Models (SwiftData):** `Photo`, `ExifRecord`, `Enrichment`, `RotationRule`, `Filter`, `OverlayStyle`, `Favorite`, `HistoryEvent`, `SyncPrefs`.
- **Services:** one type per external concern. Each is a protocol + real impl + mock for tests.
  - `UnsplashService` — search, photo detail, download.
  - `OllamaService` — chat with strict JSON output; optional web-search tool hook.
  - `BuildingDetector` — pure text/tag function.
  - `ExifReader` — `ImageIO` / `CGImageSource` wrapper.
  - `WallpaperService` — `NSWorkspace` desktop image APIs, multi-display.
  - `SpaceObserver` — wraps `NSWorkspace.activeSpaceDidChangeNotification`, exposes an `AsyncStream` of Space changes.
  - `ImageCache` — disk LRU with size cap.
  - `Store` — SwiftData model container, CRUD, queries.
  - `OverlayRenderer` — Core Image composition.
  - `Scheduler` — next-fire time from a rule and clock.
  - `SyncEngine` — wraps SwiftData + CloudKit, exposes status, conflict handling.
  - `KeychainService` — get/set/delete, toggle `synchronizable`.
- **Engine:** `RotationEngine` actor. Sole owner of rotation state: pick → fetch → read EXIF → enrich → apply → schedule next. Listens to `SpaceObserver` to apply per-Space rules.
- **ViewModels:** one per tab. Observe `Store`, call services. Views do not call services directly.
- **Views:** SwiftUI, thin, one file per screen. Previews use mocks.

### Concurrency
- Swift Concurrency end to end (`async/await`, actors, `@ModelActor` for SwiftData writes).
- `RotationEngine` is an actor so scheduling cannot race.
- Strict concurrency enabled in Swift 6 mode.

### Error handling
- Every service returns a typed error. Views turn errors into the menu bar status dot and a toast, not blocking alerts.
- If Unsplash is unreachable: rotate from pre-cache.
- If Ollama is unreachable or returns bad JSON: photo rotates anyway with `area-only` info.
- If iCloud is unreachable: queue changes locally; retry on reachability.

### Widget
- Separate WidgetKit target. Small, medium, and large sizes.
- Widget layout options (user-chosen in Overlay tab): **Blurb** (name + architect + one-sentence), **EXIF** (camera + lens + aperture + ISO + taken-at), **Minimal** (name only), **Photographer** (author name + location + license).
- The app writes a `WidgetPayload` JSON to the shared App Group on every rotation and calls `WidgetCenter.reloadAllTimelines()`.

---

## 5. Files Organization

```
paperpaper/
├─ paperpaper.xcodeproj/
├─ paperpaper/                           # app target
│  ├─ App/
│  │  ├─ paperpaperApp.swift             # @main, menu bar + window setup
│  │  ├─ AppEnvironment.swift            # service registry, injected via .environment
│  │  └─ MenuBarController.swift
│  ├─ Features/
│  │  ├─ Now/
│  │  ├─ Library/
│  │  ├─ Discover/
│  │  ├─ Rotation/
│  │  ├─ Overlay/
│  │  ├─ Cache/
│  │  ├─ Sync/
│  │  ├─ Connections/
│  │  └─ Advanced/
│  ├─ Services/
│  │  ├─ UnsplashService.swift
│  │  ├─ OllamaService.swift
│  │  ├─ BuildingDetector.swift
│  │  ├─ ExifReader.swift
│  │  ├─ WallpaperService.swift
│  │  ├─ SpaceObserver.swift
│  │  ├─ ImageCache.swift
│  │  ├─ OverlayRenderer.swift
│  │  ├─ Scheduler.swift
│  │  ├─ Store.swift
│  │  ├─ SyncEngine.swift
│  │  └─ KeychainService.swift
│  ├─ Engine/
│  │  └─ RotationEngine.swift
│  ├─ Models/
│  │  ├─ Photo.swift
│  │  ├─ ExifRecord.swift
│  │  ├─ Enrichment.swift
│  │  ├─ RotationRule.swift
│  │  ├─ Filter.swift
│  │  ├─ OverlayStyle.swift
│  │  ├─ Favorite.swift
│  │  ├─ HistoryEvent.swift
│  │  └─ SyncPrefs.swift
│  ├─ Shared/                            # shared with widget target
│  │  ├─ WidgetPayload.swift
│  │  └─ AppGroup.swift
│  ├─ Resources/
│  │  ├─ Assets.xcassets
│  │  └─ Localizable.strings
│  └─ Info.plist
├─ paperpaperWidget/                     # widget extension target
│  ├─ paperpaperWidget.swift
│  ├─ Provider.swift
│  └─ Views/
│     ├─ BlurbLayout.swift
│     ├─ ExifLayout.swift
│     ├─ MinimalLayout.swift
│     └─ PhotographerLayout.swift
├─ paperpaperTests/
│  ├─ BuildingDetectorTests.swift
│  ├─ ExifReaderTests.swift
│  ├─ SchedulerTests.swift
│  ├─ ImageCacheTests.swift
│  ├─ SpaceObserverTests.swift
│  ├─ SyncEngineTests.swift
│  └─ UnsplashServiceTests.swift         # URLProtocol mocks
├─ paperpaperUITests/
├─ plan.md
├─ imaginations.md
└─ .gitignore
```

The nested `paperpaper/paperpaper.xcodeproj/` in the current repo should be deleted — it is an accident.

---

## 6. Requirements

### Build-time
- Xcode 26 or newer.
- Swift 6, strict concurrency.
- SwiftUI, **SwiftData** (CloudKit-backed), WidgetKit, AppKit (`NSWorkspace`, `NSStatusItem`), Core Image, ImageIO.

### Runtime (user's machine)
- macOS 26 or newer (for Liquid Glass). Fallback to macOS 14 possible if needed; we lose Liquid Glass styling.
- An Unsplash developer account + API key (free).
- Ollama installed locally, with a chat-capable model pulled. Web-search tool optional.
- For iCloud sync: signed in to iCloud on the device, app allowed under iCloud Drive + CloudKit.

### External services
- `api.unsplash.com` — search and metadata.
- `images.unsplash.com` — image bytes.
- `localhost:11434` (default Ollama) or user's configured host.
- Apple CloudKit (only if iCloud sync enabled).

### Persistence choice — SwiftData, not Core Data
- Chosen because: Swift-native, less boilerplate, SwiftUI-first (`@Query`), one-line CloudKit sync, `@ModelActor` for background writes, enough power for this app's simple model graph.
- Core Data is not chosen because: the extra power (complex migrations, heavy fetch tuning, mature tooling) does not map to anything we need here, and the API cost is meaningful.

---

## 7. Permissions

- **Outgoing network** — for Unsplash, Ollama (if remote), and CloudKit. Declared in entitlements (`com.apple.security.network.client`). No prompt.
- **App Group** — for widget sharing (`com.apple.security.application-groups`). No prompt.
- **iCloud containers + CloudKit** — enabled in entitlements if sync is on. No runtime prompt beyond the user being signed into iCloud on the Mac.
- **User-selected file access (read/write)** — only when the user exports a favorite or imports a local image.
- **Notifications** — optional, opt-in, only if the user wants "notify when wallpaper changes."
- **No location permission.** We do not read the user's location. The GPS in EXIF is the *photo's* GPS, not the user's, and comes from the downloaded image file.
- **No full disk access, accessibility, camera, microphone, contacts, or calendar.**

Info.plist has no usage descriptions except the optional notification one.

---

## 8. Privacy

- **No analytics, no telemetry, no crash reporting sent to us or any third party.**
- **No account system.** The app has no user identity.
- **Keys (Unsplash, Ollama)** live in the Keychain. Not logged. Synced to iCloud Keychain only if the user opts in.
- **History, favorites, EXIF, and enrichment records** live in SwiftData under the app's sandbox container. If iCloud sync is enabled, they sync through the user's own iCloud account — not through us.
- **Photo metadata including GPS lat/long** is public data that belongs to the photograph (uploaded by the photographer to Unsplash under the Unsplash license). We store it because photographers want it visible, and we show it in the Now tab and optionally in the widget. This is photo metadata, not user location.
- **The user's own location is never collected.** The app does not request Core Location.
- **LLM prompts sent to Ollama** contain only the photo's title, description, tags, location text, and optionally the photo's GPS. Never any personal data about the user.
- **Attribution** per Unsplash's API terms: author name and link shown wherever the photo appears, including in exports.
- **Privacy panel** in Connections: plain-language summary of what is stored and where, with a one-click "Delete all local data" and "Delete all iCloud data" button.

---

## 9. Implementation Plan and TODO

Each step produces something runnable. Do not move on until the step works end-to-end.

### Step 0 — Project hygiene
- [ ] Delete the nested `paperpaper/paperpaper.xcodeproj/`.
- [ ] Confirm `.gitignore` catches `xcuserdata`, `DerivedData`, `.DS_Store`, `.env`.
- [ ] First commit.

### Step 1 — Skeleton
- [ ] Xcode project set to macOS 26, Swift 6, SwiftUI lifecycle, strict concurrency on.
- [ ] Menu bar item (`NSStatusItem`) with placeholder popover.
- [ ] Main window with `TabView` and stub views for all nine tabs.
- [ ] Second target `paperpaperWidget` with an empty timeline.
- [ ] App Group enabled on both targets.

### Step 2 — Storage (SwiftData)
- [ ] Define `Photo`, `ExifRecord`, `Enrichment`, `RotationRule`, `Filter`, `OverlayStyle`, `Favorite`, `HistoryEvent`, `SyncPrefs` as `@Model` classes.
- [ ] `Store` facade with CRUD + queries.
- [ ] Seed fake data. Render in Library tab grid.

### Step 3 — Unsplash + EXIF
- [ ] Keychain helper. Connections UI to enter the Unsplash key.
- [ ] `UnsplashService.search / photo / download`.
- [ ] `ExifReader` that parses camera / lens / focal / aperture / shutter / ISO / taken-at / GPS / orientation from downloaded bytes using `ImageIO`.
- [ ] Discover tab shows live results with EXIF blocks.

### Step 4 — Wallpaper apply (single Space)
- [ ] `WallpaperService` over `NSWorkspace.setDesktopImageURL` per `NSScreen`.
- [ ] "Set as wallpaper" button on any Discover result. Verify on multi-display.

### Step 5 — Rotation engine
- [ ] `Scheduler` with interval + day/night schedule.
- [ ] `RotationEngine` actor: pick → fetch → EXIF → apply.
- [ ] Rotation tab UI. Persist the rule; resume on launch.

### Step 6 — Cache + pre-fetch
- [ ] `ImageCache` LRU with size cap.
- [ ] Pre-cache next N after every rotation (N user-set, default 3).
- [ ] Cache tab: size, hit rate, clear buttons.

### Step 7 — Building detection + Ollama
- [ ] `BuildingDetector` pure function. Fixture file of real captions.
- [ ] `OllamaService` with strict JSON schema output.
- [ ] Hook enrichment into the engine. Show on Now tab.

### Step 8 — Spaces awareness
- [ ] `SpaceObserver` wrapping the active-space notification.
- [ ] Rotation tab exposes the three Space modes (Unified / Per-Space / Active-only).
- [ ] Verify manually that Space switches behave as designed.

### Step 9 — Widget + layouts
- [ ] Shared `WidgetPayload` struct with every field for every layout.
- [ ] On every rotation, write payload to App Group, call `WidgetCenter.reloadAllTimelines()`.
- [ ] Implement four widget layouts (Blurb / EXIF / Minimal / Photographer).
- [ ] Small, medium, and large sizes.

### Step 10 — Overlay (burn-in text)
- [ ] `OverlayRenderer` (Core Image) producing a composite file.
- [ ] Overlay tab with debounced live preview.
- [ ] Engine applies the composite file when overlay is enabled.

### Step 11 — Filters, pools, per-display
- [ ] Color, aspect-ratio, camera, lens, focal-length, country filters.
- [ ] Separate light-mode / dark-mode pools.
- [ ] Per-display rotation rules.

### Step 12 — iCloud sync
- [ ] Configure SwiftData store with CloudKit.
- [ ] Sync tab with per-scope toggles, status, conflict surfacing.
- [ ] Keychain items switch to `kSecAttrSynchronizable` when the user opts into key sync.
- [ ] Manual test: flip settings on one device, watch them arrive on another.

### Step 13 — Advanced settings / diagnostics
- [ ] Advanced tab with every knob (timeouts, retries, max pre-fetch, logging level, reset all).
- [ ] Export diagnostic bundle (logs + prefs, image bytes excluded).

### Step 14 — Polish
- [ ] Liquid Glass pass on every surface.
- [ ] Accessibility (VoiceOver labels, contrast, dynamic type where applicable).
- [ ] Localization strings extracted.
- [ ] Empty / error / offline states everywhere.

### Step 15 — Ship
- [ ] Hardened runtime enabled.
- [ ] Notarize and sign.
- [ ] README with screenshots and a short getting-started.

---

## 10. Validation Method

### Automated
- **Unit tests:**
  - `BuildingDetector`: 50+ real Unsplash captions as fixtures; stoplist tuned to 90%+ agreement.
  - `ExifReader`: test images with known EXIF; parse matches expected values; handles missing fields.
  - `Scheduler`: correct next-fire across DST, midnight, sleep/wake.
  - `ImageCache`: LRU eviction, size cap, corrupted-file recovery.
  - `SpaceObserver`: stubbed notification center, emits the expected events.
  - `SyncEngine`: stubbed CloudKit, verifies queue/flush behavior and conflict resolution path.
  - `UnsplashService` + `OllamaService`: `URLProtocol` stubs, asserts on requests and parsing.
- **UI smoke tests (XCUITest):** app launches, menu bar item appears, window opens, every tab renders without crashing.

### Manual checklist (before any release)
- [ ] Second display plugged in — wallpaper applies correctly on both.
- [ ] Display unplugged — no crash; next rotation uses remaining screens.
- [ ] Sleep 10 minutes, wake — rotation catches up without firing a storm.
- [ ] Quit and relaunch — rule, history, and Space state restore.
- [ ] Switch Spaces in each of the three Space modes — behavior matches expectation.
- [ ] Wi-Fi off — pre-cached photos still rotate, offline dot shown.
- [ ] Ollama off — rotation continues with `area-only` info, no blocking errors.
- [ ] iCloud sync: change a setting on device A, verify it lands on device B within a minute.
- [ ] Widget updates within two rotations; every layout renders correctly at small, medium, and large.
- [ ] Cache cap honored within 10% under sustained rotation.
- [ ] An hour on battery — `powermetrics` shows reasonable energy impact.

### Performance budgets (Instruments)
- Idle memory: under 150 MB.
- CPU during a rotation: under 20% for under 2 seconds on an M-series Mac.
- Overlay preview: under 30% GPU during slider drags.
- Sync traffic: negligible on idle; bounded by the number of settings/photos changed.

### Definition of "v1 done"
The app runs unattended for a week on a multi-display, multi-Space Mac, rotating architecture wallpapers on schedule, showing building names for recognizable landmarks and full EXIF for every photo, updating a widget in the user's chosen layout, optionally syncing settings and history through iCloud to a second Mac, never exceeding its performance budgets, with zero crashes in that week.
