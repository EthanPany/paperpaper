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

    func rotateNow() async {
        await rotate()
    }

    private func handleSpaceChange() async {
        let rule = Store.shared.rule()
        guard rule.spaceMode == .unified else { return }

        let descriptor = FetchDescriptor<Photo>(sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)])
        guard let recent = try? Store.shared.context.fetch(descriptor).first(where: { $0.lastSeenAt != nil }) else { return }
        _ = try? await WallpaperApplier.shared.reapply(photo: recent)
    }

    private func loop() async {
        try? await Task.sleep(for: .seconds(1))
        if Task.isCancelled { return }
        await rotate()

        while !Task.isCancelled {
            let rule = Store.shared.rule()
            guard rule.enabled else {
                stop()
                return
            }
            let fire = Scheduler.nextFire(for: rule)
            nextFireAt = fire
            let interval = max(5, fire.timeIntervalSince(.now))
            try? await Task.sleep(for: .seconds(interval))
            if Task.isCancelled { return }
            await rotate()
        }
    }

    private func rotate() async {
        do {
            let filters = Store.shared.filters()
            let topic = filters.topics.randomElement() ?? "architecture"
            let prefetchCount = UserDefaults.standard.object(forKey: "cache.prefetchCount") as? Int ?? 3
            let photos = try await UnsplashService.shared.random(query: topic, count: 1 + prefetchCount)
            let eligible = photos.filter { candidate in
                acceptCandidate(candidate, filters: filters)
            }
            guard let first = eligible.first ?? photos.first else { return }

            let applied = try await WallpaperApplier.shared.apply(unsplash: first)
            lastError = nil

            Task {
                await WallpaperApplier.shared.enrichIfNeeded(applied)
            }

            let remaining = eligible.dropFirst().prefix(prefetchCount)
            for candidate in remaining {
                await WallpaperApplier.shared.preCache(candidate)
            }
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func acceptCandidate(_ photo: UnsplashPhoto, filters: FilterPrefs) -> Bool {
        let aspect = Double(photo.width) / Double(max(photo.height, 1))
        if aspect < filters.minAspect || aspect > filters.maxAspect { return false }

        let tagTitles = (photo.tags ?? []).map(\.title.localizedLowercase)
        for excluded in filters.excludedTags where !excluded.isEmpty {
            if tagTitles.contains(excluded.localizedLowercase) { return false }
        }

        if let needle = filters.countryContains, !needle.isEmpty {
            let country = photo.location?.country?.localizedLowercase ?? ""
            if !country.contains(needle.localizedLowercase) { return false }
        }
        if let needle = filters.cameraContains, !needle.isEmpty {
            let camera = [photo.exif?.make, photo.exif?.model].compactMap { $0 }.joined(separator: " ").localizedLowercase
            if !camera.contains(needle.localizedLowercase) { return false }
        }
        return true
    }
}
