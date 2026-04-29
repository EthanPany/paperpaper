# paperpaper — App Store Connect copy

Paste each section into the matching field in App Store Connect.
Anything in `<<…>>` is a placeholder for you to fill before submitting.

---

## App Name (max 30 chars)

paperpaper

> alt: `paperpaper — Live Wallpapers`

## Subtitle (max 30 chars)

Architecture wallpapers, daily.

> alts:
> - `Daily place-aware wallpapers`
> - `Wallpapers with stories`
> - `Wallpapers that know places`

## Promotional Text (max 170 chars, editable any time without resubmit)

Fresh photography on your desktop, every day. paperpaper recognises the place in each shot and writes a short note about it — quietly, on your machine.

## Description (max 4000 chars)

paperpaper rotates a fresh photograph onto your Mac desktop on whatever schedule you like — every hour, every morning, every Friday. Each wallpaper comes with a short, written note about the place: the building, the street, the city block. Notes are generated on-device by your local Ollama model, so the photos and the prose stay on your Mac.

Highlights

• Curated rotation. Pick a topic ("brutalism", "tokyo at night", "alpine lakes") or let paperpaper surface a varied feed.
• Built-in widgets. Three widget styles — Photo, Card, and Clear — in small, medium, and large sizes. Each shows the location, the photographer, and an AI-written note tuned to the widget's size.
• Place-aware. paperpaper reads the signs in the photo (theatre marquees, station boards, store fronts) along with EXIF GPS to identify what you're actually looking at. No best-guess hallucinations: when it doesn't know, it doesn't say.
• Local AI. The architecture-recognition agent runs through Ollama on your Mac. No photo or metadata is sent to any third-party AI service. If you don't have Ollama installed, paperpaper still works as a clean rotation tool — the captions just stay blank.
• iCloud sync. Set the rotation rule on one Mac and your other Macs follow along. Configuration only — no photo sync, no account required.
• Menu bar first. paperpaper lives in the menu bar by default. Open the popover for a thumbnail of the current wallpaper, the next rotation time, and one-tap controls: rotate now, regenerate the AI note, reapply, pause.
• Polite to your network. Photos are pulled from Unsplash with full photographer attribution and a click-through link to their profile. Cache size is capped — you control the limit.

How it works

Pick a rotation interval and a couple of search topics in Settings. paperpaper downloads a small batch ahead of time, sets the next photo as your wallpaper when the timer fires, and runs the local recognition agent in the background so the widget caption is ready when you glance at it. If a run fails, paperpaper retries the next time you see the photo — it never marks something "reviewed" without an actual answer.

Privacy

paperpaper does not collect, store, or transmit personal data. The only outbound network calls are to Unsplash (to fetch photos and report downloads, as required by the Unsplash API) and, optionally, to your locally-running Ollama instance for the AI note. There is no analytics SDK, no crash reporter, no advertising network.

Requirements

• macOS 26 or later
• Optional: Ollama (https://ollama.com) running locally, with a vision-capable model installed (we default to qwen3-vl:2b-instruct).
• Optional: a free Unsplash API access key for higher rate limits — paperpaper guides you through generating one on first launch.

## Keywords (max 100 chars, comma-separated, no spaces around commas — single string)

wallpaper,desktop,rotate,unsplash,widget,photo,architecture,scenery,daily,menubar

## Support URL (required)

<<https://your-website-or-github-page.example/paperpaper/support>>

> If you don't have one yet, a one-page GitHub repo README with a "Report an issue" link works for review.

## Marketing URL (optional)

<<https://your-website-or-github-page.example/paperpaper>>

## Privacy Policy URL (REQUIRED — App Store Connect blocks submission without one)

<<https://your-website-or-github-page.example/paperpaper/privacy>>

> Use the privacy.md document in this folder as the source.

## Copyright

2026 Ethan Pan

## Primary Category

Graphics & Design

## Secondary Category

Lifestyle

## Age Rating

4+ (no objectionable content). When the questionnaire asks about user-generated content, the answer is **No** — users only consume Unsplash editorial photography filtered through paperpaper.

---

## App Privacy Questionnaire — answers

App Store Connect → App Information → App Privacy.

**Do you collect data from this app?** No.

If review pushes back because you make outbound network calls, the rationale is:

- Unsplash photo URLs are fetched anonymously via the Unsplash API. paperpaper hits `download_location` per Unsplash's TOS — this is not user data, it's a per-photo download attribution ping required by Unsplash.
- Ollama runs on the user's own machine. It is not a "third-party SDK" in the App Store Connect sense.
- No identifiers, telemetry, advertising, or crash reporters are bundled.

So the data-types page should remain empty.

## Export Compliance

In Info.plist add (if not already):

```
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

This sets you to "uses only exempt encryption" (HTTPS via stock URLSession), which skips the encryption questionnaire on every upload.

---

## What's New in This Version (max 4000 chars — fill on every release)

First public release. Hello!

> For the next release replace with bullet points.

## Review Notes (private; only Apple reviewers see this)

paperpaper is a desktop wallpaper rotator with WidgetKit widgets.

Optional local AI: paperpaper can call a locally-installed Ollama instance (https://ollama.com) on `127.0.0.1:11434` for on-device place identification and short captions. The app functions normally without Ollama — captions are simply empty. **Reviewers do not need to install Ollama**; please rotate any photo and observe the wallpaper changes. If you wish to test the AI captioning, install Ollama and run `ollama pull qwen3-vl:2b-instruct` before launching the app.

To exercise the rotation flow during review:
1. Launch paperpaper. The menu bar icon appears.
2. Click the menu bar icon → "Rotate now". A new wallpaper from Unsplash will be set on the desktop.
3. Add the paperpaper widget from the macOS widget gallery — three styles are available.

Unsplash API: paperpaper fetches photos from Unsplash via the public REST API with an access key embedded in the build. We comply with Unsplash's API guidelines including the `download_location` tracking ping and full photographer attribution. The Unsplash production application has been registered.

Privacy: no analytics, no crash reporters, no third-party SDKs. The only outbound calls are to api.unsplash.com and (if Ollama is installed) 127.0.0.1:11434.

## Demo Account

Not required — paperpaper has no login.
