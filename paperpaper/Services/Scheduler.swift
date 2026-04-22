import Foundation

enum Scheduler {
    /// Returns the absolute time of the next scheduled rotation, honoring schedule
    /// mode, clock alignment, specific times, and days-of-week mask.
    static func nextFire(for rule: RotationRule, after: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> Date {
        let mask = rule.daysOfWeekMask == 0 ? 0b1111111 : rule.daysOfWeekMask

        for dayOffset in 0..<14 {
            guard let dayStart = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: after)) else { continue }
            let weekday = calendar.component(.weekday, from: dayStart)
            guard mask & (1 << (weekday - 1)) != 0 else { continue }

            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
            let earliest = max(after, dayStart)

            if let fire = nextCandidate(dayStart: dayStart, dayEnd: dayEnd, earliest: earliest, rule: rule) {
                return fire
            }
        }
        return after.addingTimeInterval(Double(max(5, rule.intervalSeconds)))
    }

    /// Convenience for callers that want seconds until the next fire.
    static func nextIntervalSeconds(for rule: RotationRule, at after: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> Int {
        let fire = nextFire(for: rule, after: after, calendar: calendar)
        return max(5, Int(fire.timeIntervalSince(after).rounded()))
    }

    static func isDaytime(rule: RotationRule, at now: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        let hour = calendar.component(.hour, from: now)
        return hour >= rule.dayStartHour && hour < rule.nightStartHour
    }

    private static func nextCandidate(dayStart: Date, dayEnd: Date, earliest: Date, rule: RotationRule) -> Date? {
        switch rule.scheduleMode {
        case .interval:
            let interval = max(5, rule.intervalSeconds)
            if rule.alignToClock {
                let elapsed = Int(earliest.timeIntervalSince(dayStart))
                let nextMultiple = ((elapsed / interval) + 1) * interval
                let candidate = dayStart.addingTimeInterval(Double(nextMultiple))
                if candidate >= dayEnd { return nil }
                return candidate > earliest ? candidate : nil
            }
            let candidate = earliest.addingTimeInterval(Double(interval))
            return candidate < dayEnd ? candidate : nil

        case .specificTimes:
            let times = rule.specificMinutesOfDay.sorted()
            guard !times.isEmpty else { return nil }
            let elapsedMinutes = Int(earliest.timeIntervalSince(dayStart) / 60)
            for minute in times where minute > elapsedMinutes {
                let candidate = dayStart.addingTimeInterval(Double(minute * 60))
                if candidate < dayEnd { return candidate }
            }
            return nil
        }
    }
}

enum Weekday: Int, CaseIterable {
    case sun = 1, mon, tue, wed, thu, fri, sat

    var shortLabel: String {
        switch self {
        case .sun: "S"
        case .mon: "M"
        case .tue: "T"
        case .wed: "W"
        case .thu: "T"
        case .fri: "F"
        case .sat: "S"
        }
    }

    var fullLabel: String {
        switch self {
        case .sun: "Sunday"
        case .mon: "Monday"
        case .tue: "Tuesday"
        case .wed: "Wednesday"
        case .thu: "Thursday"
        case .fri: "Friday"
        case .sat: "Saturday"
        }
    }

    var bit: Int { 1 << (rawValue - 1) }
}
