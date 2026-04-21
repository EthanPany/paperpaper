import Foundation

enum Scheduler {
    static func nextIntervalSeconds(for rule: RotationRule, at now: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> Int {
        switch rule.dayNightMode {
        case .off:
            return max(5, rule.intervalSeconds)
        case .separatePools:
            return max(5, rule.intervalSeconds)
        case .separateIntervals:
            let hour = calendar.component(.hour, from: now)
            let isDay = hour >= rule.dayStartHour && hour < rule.nightStartHour
            return max(5, isDay ? rule.intervalSeconds : rule.nightIntervalSeconds)
        }
    }

    static func isDaytime(rule: RotationRule, at now: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        let hour = calendar.component(.hour, from: now)
        return hour >= rule.dayStartHour && hour < rule.nightStartHour
    }
}
