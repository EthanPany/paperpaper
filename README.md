# paperpaper

A macOS app that rotates a fresh photograph onto your desktop on whatever schedule you like, and writes a short note about the place in each shot — quietly, on your own machine.

- **Place-aware** — reads the signs in each photo (theatre marquees, station boards, store fronts) along with EXIF GPS to identify what you're looking at. No best-guess hallucinations: when it doesn't know, it doesn't say.
- **Local AI** — the architecture-recognition agent runs through [Ollama](https://ollama.com) on your Mac. No photo or metadata is sent to any third-party AI service.
- **Built-in widgets** — three styles (Photo, Card, Clear) in three sizes, each with a length-tuned AI caption.
- **iCloud sync** — config-only sync between your own Macs via `NSUbiquitousKeyValueStore`. Photos stay local.
- **Menu bar first** — quick rotate, regenerate, reapply, pause from a popover.

Photos come from [Unsplash](https://unsplash.com) with full photographer attribution.

## Status

In review for the Mac App Store as of April 2026 — version 1.0, bundle ID `me.ethanpan.paperpaper`. Listing live shortly at the App Store.

Until then this repo is the source of record. Pull, build, run.

## Requirements

- macOS 26+
- Xcode 26+
- Optional: [Ollama](https://ollama.com) running locally, with `ollama pull qwen3-vl:2b-instruct` for AI captions
- Optional: a free [Unsplash API access key](https://unsplash.com/developers) for higher rate limits — the app guides you through getting one on first launch

## Build

```bash
git clone https://github.com/EthanPany/paperpaper-wallpaper-app.git
cd paperpaper-wallpaper-app
open paperpaper.xcodeproj
# In Xcode: select the paperpaper scheme + "My Mac" destination, then Run.
```

Or headless:

```bash
xcodebuild -project paperpaper.xcodeproj \
  -scheme paperpaper \
  -destination 'platform=macOS' \
  -configuration Debug build
```

## Architecture

```
paperpaper/                 main app target
  App/                      AppDelegate, MenuBarContent, MainWindowRouter
  Engine/                   RotationEngine — schedules and triggers rotations
  Features/
    Now/                    NowView — main window glass card
    Discover/               topic search + manual photo picking
    Library/                history, favourites, hidden
    Connections/            Unsplash + Ollama setup, status
    Schedule/               rotation rule editor
  Models/                   SwiftData @Model types — Photo, Enrichment, ExifRecord, etc.
  Services/
    UnsplashService.swift   REST client — search, random, downloadLocation tracking
    OllamaService.swift     /api/chat with manual JSON serialization to dodge
                            tool-spec stringification bugs in qwen3-vl
    ArchitectureAgent.swift vision + MapKit + web_search agent loop
    WallpaperApplier.swift  apply / reapply / write widget payload / enrich
    WallpaperService.swift  NSWorkspace setDesktopImageURL on all screens
    iCloudSyncCoordinator   KVS-only config sync across user's Macs
    Store.swift             SwiftData stack (CloudKit pinned to .none)
  Shared/
    WidgetPayload.swift     Codable struct shared with the widget extension
                            via App Group group.me.ethanpan.paperpaper

paperpaperWidget/           WidgetKit extension
  paperpaperWidget.swift    AppIntentConfiguration with photo/architecture mode
                            and Photo / Card / Clear layouts at 3 sizes
  WidgetPayload.swift       extension's read-side copy (App Group + UserDefaults)

AppStore/                   App Store Connect listing source-of-truth
  listing.md                description, keywords, review notes
  privacy.md                privacy policy hosted at the support URL
  screenshots.md            capture plan
  preflight.md              archive checklist

media/                      icon source + raw + processed screenshots
```

## How the agent works

`ArchitectureAgent.swift` runs an iterative tool-using loop against a local Ollama vision model. The model sees the wallpaper image plus everything the app already knows (Unsplash description, EXIF GPS, area string, MapKit nearby landmarks). It can call:

- `mapkit_search(query, lat?, lon?, radius?)` — Apple Maps local search
- `web_search(query)` — Ollama-hosted web search (when an API key is set)
- `commit_enrichment(building_name?, location, blurb_short, blurb_medium, blurb_long)` — terminal call

The system prompt teaches it to (a) read visible text in the image first, (b) treat chain storefronts as tenants not subjects, and (c) keep architect/year/style as prose inside the blurbs rather than separate fields. Three blurb lengths feed the small / medium / large widgets respectively. If the model exhausts its iterations without committing, a final text-JSON pass forces a commit. Failed runs leave `enrichedAt = nil` so the next view of that photo re-runs.

## License & credits

App source: © 2026 Ethan Pan. License TBD (probably MIT).

Photos and photo metadata are served by Unsplash and remain credited to the photographers shown in-app.

The architecture caption agent runs locally via Ollama — no third-party AI service is involved.

## Support

[github.com/EthanPany/paperpaper-wallpaper-app/issues](https://github.com/EthanPany/paperpaper-wallpaper-app/issues) · pyy122759996@gmail.com
