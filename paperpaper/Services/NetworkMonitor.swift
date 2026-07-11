import Foundation
import Network

/// Lightweight reachability flag backed by a single long-lived `NWPathMonitor`.
///
/// The rotation engine only needs a yes/no "do we have a usable path right now"
/// before it hits Unsplash — not per-request probing. We start one monitor at
/// app launch and read `isConnected` synchronously on the main actor.
@MainActor
@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    /// Defaults to `true` so a not-yet-started monitor never falsely blocks a
    /// rotation. The first path update (usually within milliseconds of start)
    /// corrects it.
    private(set) var isConnected: Bool = true

    @ObservationIgnored
    private let monitor = NWPathMonitor()
    @ObservationIgnored
    private let queue = DispatchQueue(label: "me.ethanpan.paperpaper.network-monitor")
    @ObservationIgnored
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor in
                self?.isConnected = connected
            }
        }
        monitor.start(queue: queue)
    }
}
