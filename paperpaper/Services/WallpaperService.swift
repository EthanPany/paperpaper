import Foundation
import os
#if os(macOS)
import AppKit
#endif

@MainActor
final class WallpaperService {
    static let shared = WallpaperService()

    private let log = Logger(subsystem: "me.ethanpan.paperpaper", category: "wallpaper")

    #if os(macOS)
    var allScreens: [NSScreen] { NSScreen.screens }

    func currentImageURL(for screen: NSScreen) -> URL? {
        NSWorkspace.shared.desktopImageURL(for: screen)
    }

    /// Set the desktop image on every screen.
    ///
    /// Note: we deliberately do NOT read `desktopImageURL(for:)` back to
    /// "verify" the set. macOS updates that read API asynchronously, so an
    /// immediate read-back routinely still returns the PREVIOUS image even
    /// though the set succeeded — a false alarm. (A genuinely blocked set —
    /// e.g. a Dynamic/Aerial wallpaper refusing to yield on macOS 14–26 — can't
    /// be reliably distinguished from that lag synchronously, so we don't try.)
    func setOnAllScreens(imageURL: URL) throws {
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true,
        ]
        for screen in allScreens {
            try NSWorkspace.shared.setDesktopImageURL(imageURL, for: screen, options: options)
        }
        log.info("wallpaper set: \(imageURL.lastPathComponent, privacy: .public)")
    }

    /// Re-set the desktop image **only on screens that aren't already showing
    /// it**. Used by the cross-Space follow path on every active-space change.
    ///
    /// Reading `desktopImageURL(for:)` here is safe — unlike the read-back-to-
    /// *verify* case warned about above. There we read immediately after a set
    /// (laggy, returns the old value); here we read *before* setting, on a
    /// Space change where any earlier set has long since settled, so the value
    /// is reliable. Skipping screens already on the target avoids re-pushing
    /// the image through the legacy `setDesktopImageURL` path — which, when the
    /// Space currently shows a macOS Dynamic wallpaper, forces WallpaperAgent
    /// and the Dock to tear that wallpaper down and rebuild it (the visible
    /// "flash to the system default, then back" plus the Dock freeze). A Space
    /// we've already pushed to does zero work; one that genuinely lacks the
    /// wallpaper pays the one-time set, then sticks.
    ///
    /// Returns true if at least one screen actually needed the set.
    @discardableResult
    func reapplyOnAllScreensIfNeeded(imageURL: URL) throws -> Bool {
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true,
        ]
        let target = imageURL.resolvingSymlinksInPath().path
        var changed = false
        for (i, screen) in allScreens.enumerated() {
            let current = currentImageURL(for: screen)?.resolvingSymlinksInPath().path
            let currentName = current.map { ($0 as NSString).lastPathComponent } ?? "nil"
            if current == target {
                log.info("reapply screen[\(i, privacy: .public)]: already on \(imageURL.lastPathComponent, privacy: .public) — skip")
                continue
            }
            log.info("reapply screen[\(i, privacy: .public)]: current=\(currentName, privacy: .public) → setting \(imageURL.lastPathComponent, privacy: .public)")
            try NSWorkspace.shared.setDesktopImageURL(imageURL, for: screen, options: options)
            changed = true
        }
        if changed {
            log.info("wallpaper reapplied on space change: \(imageURL.lastPathComponent, privacy: .public)")
        }
        return changed
    }

    func set(imageURL: URL, on screen: NSScreen) throws {
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true,
        ]
        try NSWorkspace.shared.setDesktopImageURL(imageURL, for: screen, options: options)
    }
    #endif
}
