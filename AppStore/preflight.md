# Pre-flight checklist

Before you click "Archive" in Xcode, confirm each item.

## Bundle IDs

- [ ] Main app target bundle ID is the **final** ID (no longer `ep.paperpaper2`).
- [ ] Widget extension bundle ID is `<app-id>.WidgetExtension` (or similar — must be a child of the app's ID).
- [ ] App Group on both targets is `group.<final-app-id>` and matches `WidgetPayload.appGroup` (currently `group.ep.paperpaper`).
- [ ] iCloud KVS entitlement reads `$(TeamIdentifierPrefix)$(CFBundleIdentifier)` — automatic once the bundle ID is right.

## Entitlements

- [ ] App Sandbox: ON.
- [ ] Outgoing connections (Client): ON.
- [ ] App Groups: contains the group above, on both targets.
- [ ] iCloud → Key-Value Storage: ON. (Documents and CloudKit can stay OFF — we only use KVS.)

## Info.plist

- [ ] `LSApplicationCategoryType` = `public.app-category.graphics-design`.
- [ ] `NSHumanReadableCopyright` = `© 2026 Ethan Pan`.
- [ ] `ITSAppUsesNonExemptEncryption` = `false` (skips export-compliance prompt on every upload).
- [ ] Minimum deployment target matches what the description claims (macOS 26 recommended given `.glassEffect` use).

## Signing

- [ ] Both targets: "Automatically manage signing" with your team selected.
- [ ] Provisioning profiles are App Store, not Development, when archiving Release.

## App icon

- [ ] `AppIcon` asset has every macOS slot filled, including the 1024×1024 marketing icon.
- [ ] Marketing icon is opaque (no alpha), square, and **not** pre-rounded. macOS rounds it for you.

## Unsplash

- [ ] You have submitted your application for **Production** access at https://unsplash.com/oauth/applications and Unsplash has approved it.
- [ ] Production access key is hard-coded into the app (or fetched from your own server). The development key is rate-limited to 50 req/h and Apple reviewers will hit that limit.
- [ ] `download_location` ping is firing on each apply (already wired in `WallpaperApplier.apply`).
- [ ] Photographer attribution is visible on every surface that shows a photo (NowView, MenuBarContent, all three widget styles — already wired).

## Logging hygiene

- [ ] Optional: wrap the `widget breadcrumb` writes in `paperpaperWidget/WidgetPayload.swift` behind `#if DEBUG`. Not required, just keeps user Console clean.
- [ ] The `print()` statements in `paperpaperApp.init` (if any) are fine; reviewers don't see them. Skip.

## Smoke test on a clean account

- [ ] Run on a Mac with a fresh user account — no Ollama, no Unsplash key — and confirm the app:
   - Doesn't crash.
   - Shows a clear onboarding state in Connections.
   - Falls back to the placeholder gradient + "Wallpaper" text in widgets.
   - Doesn't spam the Console with permission errors.
- [ ] Add an Unsplash key and confirm rotation works.
- [ ] Install Ollama + qwen3-vl, confirm captions show up.
- [ ] Add all three widget sizes from the widget gallery, confirm each renders.

## Build + archive

```bash
# In Xcode: select "Any Mac" as the destination, then Product → Archive.
# Or, headless:
xcodebuild -project paperpaper.xcodeproj \
  -scheme paperpaper \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath build/paperpaper.xcarchive \
  archive
```

Upload through Xcode → Organizer → Distribute App → App Store Connect.

## After upload

- [ ] Build appears in App Store Connect → TestFlight (processing takes 10–30 min).
- [ ] Add the build to your version under "App Store" tab.
- [ ] Fill every listing field from `listing.md`.
- [ ] Privacy Policy URL points at a live page rendering `privacy.md`.
- [ ] App Privacy questionnaire complete (answer: no data collected).
- [ ] Screenshots uploaded.
- [ ] Submit for review.
