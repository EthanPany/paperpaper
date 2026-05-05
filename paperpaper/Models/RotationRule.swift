import Foundation
import SwiftData

@Model
final class RotationRule {
    var enabled: Bool = false
    var scheduleModeRaw: String = ScheduleMode.interval.rawValue
    var intervalSeconds: Int = 3600
    var alignToClock: Bool = true
    var specificMinutesOfDay: [Int] = [8 * 60, 12 * 60, 18 * 60]
    var daysOfWeekMask: Int = 0b1111111  // Sun..Sat — all days by default
    var nightIntervalSeconds: Int = 3600
    var dayNightModeRaw: String = DayNightMode.off.rawValue
    var dayStartHour: Int = 7
    var nightStartHour: Int = 20
    var spaceModeRaw: String = SpaceMode.unified.rawValue
    var allowRepeats: Bool = false
    var repeatCooldownDays: Int = 30
    var preferNearby: Bool = false
    var matchDaylight: Bool = false
    var updatedAt: Date = Date.distantPast

    init(
        enabled: Bool = false,
        scheduleMode: ScheduleMode = .interval,
        intervalSeconds: Int = 3600,
        alignToClock: Bool = true,
        specificMinutesOfDay: [Int] = [8 * 60, 12 * 60, 18 * 60],
        daysOfWeekMask: Int = 0b1111111,
        nightIntervalSeconds: Int = 3600,
        dayNightMode: DayNightMode = .off,
        dayStartHour: Int = 7,
        nightStartHour: Int = 20,
        spaceMode: SpaceMode = .unified,
        allowRepeats: Bool = false,
        repeatCooldownDays: Int = 30,
        preferNearby: Bool = false,
        matchDaylight: Bool = false
    ) {
        self.enabled = enabled
        self.scheduleModeRaw = scheduleMode.rawValue
        self.intervalSeconds = intervalSeconds
        self.alignToClock = alignToClock
        self.specificMinutesOfDay = specificMinutesOfDay
        self.daysOfWeekMask = daysOfWeekMask
        self.nightIntervalSeconds = nightIntervalSeconds
        self.dayNightModeRaw = dayNightMode.rawValue
        self.dayStartHour = dayStartHour
        self.nightStartHour = nightStartHour
        self.spaceModeRaw = spaceMode.rawValue
        self.allowRepeats = allowRepeats
        self.repeatCooldownDays = repeatCooldownDays
        self.preferNearby = preferNearby
        self.matchDaylight = matchDaylight
        self.updatedAt = .now
    }

    var scheduleMode: ScheduleMode {
        get { ScheduleMode(rawValue: scheduleModeRaw) ?? .interval }
        set { scheduleModeRaw = newValue.rawValue }
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
