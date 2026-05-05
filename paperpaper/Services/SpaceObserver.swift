import Foundation
#if os(macOS)
import AppKit
#endif

@MainActor
@Observable
final class SpaceObserver {
    static let shared = SpaceObserver()

    private(set) var changeCount: Int = 0
    private var token: NSObjectProtocol?

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
                guard let self else { return }
                self.changeCount += 1
                self.onChange?()
            }
        }
        #endif
    }

    func stop() {
        #if os(macOS)
        if let t = token { NSWorkspace.shared.notificationCenter.removeObserver(t) }
        token = nil
        #endif
    }
}
