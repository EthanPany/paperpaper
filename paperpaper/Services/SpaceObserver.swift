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
        token = NotificationCenter.default.addObserver(
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
        if let t = token { NotificationCenter.default.removeObserver(t) }
        token = nil
        #endif
    }
}
