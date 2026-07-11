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
    /// Bias each rotation's Unsplash query toward the user's current city /
    /// country so the wallpaper reflects where you actually are. On by default
    /// — this is the core "based on your location" behavior. Falls back to the
    /// bare topic automatically when location is denied or unresolved, so it's
    /// safe to default on even before the user grants permission.
    var preferNearby: Bool = true
    var matchDaylight: Bool = false
    /// Skip a scheduled rotation when there's no usable network path (fetching
    /// from Unsplash would just error). On by default — it's strictly better
    /// than burning a tick on a guaranteed failure. The engine retries shortly
    /// after instead of waiting a whole interval.
    var pauseWhenOffline: Bool = true
    /// Skip a scheduled rotation while running on battery (power adapter
    /// unplugged). Off by default — opt-in for users who want to conserve power
    /// or cellular-tethered bandwidth.
    var pauseOnBattery: Bool = false
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
        preferNearby: Bool = true,
        matchDaylight: Bool = false,
        pauseWhenOffline: Bool = true,
        pauseOnBattery: Bool = false
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
        self.pauseWhenOffline = pauseWhenOffline
        self.pauseOnBattery = pauseOnBattery
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
