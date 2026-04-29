# paperpaper — Privacy Policy

_Last updated: 2026-04-29_

paperpaper is a macOS application that rotates wallpapers on your desktop and displays optional captions about the place in each photo. We have designed paperpaper to keep as much as possible on your own Mac.

## TL;DR

- paperpaper does not collect, store, or transmit any personal information.
- paperpaper has no analytics, advertising, or crash-reporting SDKs.
- The only outbound network calls are to **Unsplash** (to download wallpapers and report attribution) and, optionally, to a **locally-installed Ollama** instance on your own machine.
- Configuration may be synced between your own Macs via **Apple iCloud Key-Value Storage** if you are signed in to iCloud. Photos themselves are not synced.

## Data we collect

None. paperpaper does not have a user account, does not require a login, and does not transmit identifiers, usage telemetry, or device information to us or to any third party.

## Network calls paperpaper makes

### 1. Unsplash (api.unsplash.com)

paperpaper fetches photographs from Unsplash via the public Unsplash REST API. Specifically:

- Photo metadata and image URLs (anonymous GET requests).
- A `download_location` ping per photo, as required by the Unsplash API guidelines, when a photo is applied as a wallpaper.

These calls do not contain any personal information. They are governed by [Unsplash's Privacy Policy](https://unsplash.com/privacy).

### 2. Ollama (optional, runs locally)

If you have [Ollama](https://ollama.com) installed and running on your own Mac, paperpaper sends the wallpaper image and a short prompt to Ollama on `127.0.0.1:11434` so a local model can identify the place and write a caption. **Nothing in this flow leaves your machine.** If Ollama is not installed, paperpaper simply skips the captioning step.

### 3. iCloud (optional, Apple-managed)

If you are signed in to iCloud, paperpaper writes a small piece of configuration (rotation rule, current photo identifier, "primary device" marker) to iCloud Key-Value Storage so a second Mac signed in to the same iCloud account can mirror the rotation. Photos and AI captions are **not** synced via iCloud — only configuration. This data is stored by Apple and never reaches paperpaper's developer.

## Data stored locally on your Mac

- A SwiftData database of photos you have seen, the EXIF data extracted from them, and the captions Ollama produced.
- A bounded image cache (you control the size limit) of the photos themselves.
- Your Unsplash and Ollama API keys, stored in the macOS Keychain.

You can delete all local data by removing the app and its sandbox container at `~/Library/Containers/<bundle id>/`.

## Children's privacy

paperpaper is rated 4+ and does not collect personal data from anyone, including children.

## Changes to this policy

If we ever add functionality that changes the answers above, we will update this document and bump the "Last updated" date.

## Contact

For privacy questions, email <<your-support-email@example.com>>.
