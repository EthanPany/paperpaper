import Foundation
import os
#if os(macOS)
import AppKit
#endif

@MainActor
@Observable
final class SpaceObserver {
    static let shared = SpaceObserver()

    @ObservationIgnored
    private let log = Logger(subsystem: "me.ethanpan.paperpaper", category: "space-observer")

    private(set) var changeCount: Int = 0
    private var token: NSObjectProtocol?
    private var debounce: Timer?

    /// `activeSpaceDidChangeNotification` fires several times during a single
    /// Space transition (mid-animation, Mission Control swipes). Coalesce them
    /// so the reapply runs once, after the Space has settled — otherwise one
    /// swipe triggers a burst of legacy wallpaper sets that stalls
    /// WallpaperAgent and the Dock. 0.35s is below perception for the "the
    /// wallpaper followed me" feel but long enough to swallow the burst.
    private let debounceInterval: TimeInterval = 0.35

    var onChange: (() -> Void)?

    func start() {
        #if os(macOS)
        guard token == nil else { return }
        // NSWorkspace notifications are delivered ONLY via
        // `NSWorkspace.shared.notificationCenter` — registering on
        // `NotificationCenter.default` silently never fires. Listening on
        // the wrong center is what was making cross-space reapply
        // intermittent: it only worked while WallpaperApplier's separate
        // (correctly-registered) TTL observer was armed.
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleCoalesced()
            }
        }
        #endif
    }

    /// Reset the debounce window on every raw notification; only the final,
    /// settled Space change actually fires `onChange`.
    private func scheduleCoalesced() {
        debounce?.invalidate()
        log.info("raw activeSpaceDidChange (debouncing reapply)")
        let timer = Timer(timeInterval: debounceInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.changeCount += 1
                self.log.info("coalesced space change #\(self.changeCount, privacy: .public) → reapply")
                self.onChange?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        debounce = timer
    }

    func stop() {
        #if os(macOS)
        if let t = token { NSWorkspace.shared.notificationCenter.removeObserver(t) }
        token = nil
        #endif
        debounce?.invalidate()
        debounce = nil
    }
}
