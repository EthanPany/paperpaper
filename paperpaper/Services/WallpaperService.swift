import Foundation
#if os(macOS)
import AppKit
#endif

@MainActor
final class WallpaperService {
    static let shared = WallpaperService()

    #if os(macOS)
    var allScreens: [NSScreen] { NSScreen.screens }

    func currentImageURL(for screen: NSScreen) -> URL? {
        NSWorkspace.shared.desktopImageURL(for: screen)
    }

    func setOnAllScreens(imageURL: URL) throws {
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true,
        ]
        for screen in allScreens {
            try NSWorkspace.shared.setDesktopImageURL(imageURL, for: screen, options: options)
        }
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
