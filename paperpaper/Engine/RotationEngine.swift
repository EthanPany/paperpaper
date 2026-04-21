import Foundation
import Observation
import SwiftData

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
        SpaceObserver.shared.onChange = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.handleSpaceChange()
            }
        }
        SpaceObserver.shared.start()
        loopTask = Task { [weak self] in
            await self?.loop()
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        SpaceObserver.shared.onChange = nil
        SpaceObserver.shared.stop()
        isRunning = false
        nextFireAt = nil
    }

    private func handleSpaceChange() async {
        let rule = Store.shared.rule()
        guard rule.spaceMode == .unified else { return }

        let descriptor = FetchDescriptor<Photo>(sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)])
        guard let recent = try? Store.shared.context.fetch(descriptor).first(where: { $0.lastSeenAt != nil }) else { return }
        _ = try? await WallpaperApplier.shared.reapply(photo: recent)
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
            let prefetchCount = UserDefaults.standard.object(forKey: "cache.prefetchCount") as? Int ?? 3
            let photos = try await UnsplashService.shared.randomArchitecture(count: 1 + prefetchCount)
            guard let first = photos.first else { return }
            let applied = try await WallpaperApplier.shared.apply(unsplash: first)
            lastError = nil

            Task { [weak self] in
                _ = self
                await WallpaperApplier.shared.enrichIfNeeded(applied)
            }

            for photo in photos.dropFirst() {
                await WallpaperApplier.shared.preCache(photo)
            }
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
