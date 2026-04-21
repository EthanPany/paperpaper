import Foundation
import SwiftData

@Model
final class RotationRule {
    var enabled: Bool = false
    var intervalSeconds: Int = 3600
    var nightIntervalSeconds: Int = 3600
    var dayNightModeRaw: String = DayNightMode.off.rawValue
    var dayStartHour: Int = 7
    var nightStartHour: Int = 20
    var spaceModeRaw: String = SpaceMode.unified.rawValue
    var allowRepeats: Bool = false
    var repeatCooldownDays: Int = 30
    var updatedAt: Date = Date.distantPast

    init(
        enabled: Bool = false,
        intervalSeconds: Int = 3600,
        nightIntervalSeconds: Int = 3600,
        dayNightMode: DayNightMode = .off,
        dayStartHour: Int = 7,
        nightStartHour: Int = 20,
        spaceMode: SpaceMode = .unified,
        allowRepeats: Bool = false,
        repeatCooldownDays: Int = 30
    ) {
        self.enabled = enabled
        self.intervalSeconds = intervalSeconds
        self.nightIntervalSeconds = nightIntervalSeconds
        self.dayNightModeRaw = dayNightMode.rawValue
        self.dayStartHour = dayStartHour
        self.nightStartHour = nightStartHour
        self.spaceModeRaw = spaceMode.rawValue
        self.allowRepeats = allowRepeats
        self.repeatCooldownDays = repeatCooldownDays
        self.updatedAt = .now
    }

    var dayNightMode: DayNightMode {
        get { DayNightMode(rawValue: dayNightModeRaw) ?? .off }
        set { dayNightModeRaw = newValue.rawValue }
    }

    var spaceMode: SpaceMode {
        get { SpaceMode(rawValue: spaceModeRaw) ?? .unified }
        set { spaceModeRaw = newValue.rawValue }
    }
}
