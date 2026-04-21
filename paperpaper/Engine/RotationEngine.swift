import Foundation
import Observation

@MainActor
@Observable
final class RotationEngine {
    static let shared = RotationEngine()

    private(set) var isRunning: Bool = false
    private(set) var lastError: String?
    private(set) var nextFireAt: Date?

    private var loopTask: Task<Void, Never>?

    func startIfEnabled() {
        let rule = Store.shared.rule()
        if rule.enabled { start() } else { stop() }
    }

    func start() {
        stop()
        isRunning = true
        lastError = nil
        loopTask = Task { [weak self] in
            await self?.loop()
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        isRunning = false
        nextFireAt = nil
    }

    func rotateNow() async {
        await rotate()
    }

    private func loop() async {
        // First rotation shortly after start so the user sees an effect.
        try? await Task.sleep(for: .seconds(1))
        if Task.isCancelled { return }
        await rotate()

        while !Task.isCancelled {
            let rule = Store.shared.rule()
            guard rule.enabled else {
                stop()
                return
            }
            let interval = Scheduler.nextIntervalSeconds(for: rule)
            nextFireAt = Date().addingTimeInterval(Double(interval))
            try? await Task.sleep(for: .seconds(Double(interval)))
            if Task.isCancelled { return }
            await rotate()
        }
    }

    private func rotate() async {
        do {
            let photos = try await UnsplashService.shared.randomArchitecture(count: 1)
            guard let photo = photos.first else { return }
            _ = try await WallpaperApplier.shared.apply(unsplash: photo)
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
