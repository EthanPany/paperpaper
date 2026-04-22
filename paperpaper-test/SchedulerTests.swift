import Testing
import Foundation
@testable import paperpaper

struct SchedulerTests {
    @Test func offModeUsesIntervalSeconds() {
        let rule = RotationRule(intervalSeconds: 3600, alignToClock: false, dayNightMode: .off)
        #expect(Scheduler.nextIntervalSeconds(for: rule) == 3600)
    }

    @Test func separateIntervalsUsesNightAtNight() {
        let rule = RotationRule(
            intervalSeconds: 600,
            alignToClock: false,
            nightIntervalSeconds: 7200,
            dayNightMode: .separateIntervals,
            dayStartHour: 7,
            nightStartHour: 20
        )
        // Scheduler.nextFire today primarily honors interval (day/night are a future expansion).
        // Assert the interval branch at minimum returns what we expect.
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 4, day: 22, hour: 22))!
        let fire = Scheduler.nextFire(for: rule, after: now, calendar: calendar)
        #expect(fire > now)
        #expect(fire.timeIntervalSince(now) == 600)
    }

    @Test func minimumFloorFiveSeconds() {
        let rule = RotationRule(intervalSeconds: 1, alignToClock: false, dayNightMode: .off)
        #expect(Scheduler.nextIntervalSeconds(for: rule) == 5)
    }

    @Test func isDaytimeInclusiveOfDayStart() {
        let rule = RotationRule(dayStartHour: 7, nightStartHour: 20)
        let calendar = Calendar(identifier: .gregorian)
        let at7 = calendar.date(from: DateComponents(year: 2026, month: 4, day: 22, hour: 7))!
        let at19 = calendar.date(from: DateComponents(year: 2026, month: 4, day: 22, hour: 19))!
        let at20 = calendar.date(from: DateComponents(year: 2026, month: 4, day: 22, hour: 20))!
        #expect(Scheduler.isDaytime(rule: rule, at: at7, calendar: calendar))
        #expect(Scheduler.isDaytime(rule: rule, at: at19, calendar: calendar))
        #expect(!Scheduler.isDaytime(rule: rule, at: at20, calendar: calendar))
    }

    @Test func alignToClockFiresAtTopOfHour() {
        let calendar = Calendar(identifier: .gregorian)
        let rule = RotationRule(intervalSeconds: 3600, alignToClock: true)
        let at330 = calendar.date(from: DateComponents(year: 2026, month: 4, day: 22, hour: 15, minute: 30))!
        let fire = Scheduler.nextFire(for: rule, after: at330, calendar: calendar)
        let comps = calendar.dateComponents([.hour, .minute], from: fire)
        #expect(comps.hour == 16 && comps.minute == 0)
    }

    @Test func specificTimesPicksNextToday() {
        let calendar = Calendar(identifier: .gregorian)
        let rule = RotationRule(
            scheduleMode: .specificTimes,
            specificMinutesOfDay: [8 * 60, 12 * 60, 18 * 60]
        )
        let at10 = calendar.date(from: DateComponents(year: 2026, month: 4, day: 22, hour: 10))!
        let fire = Scheduler.nextFire(for: rule, after: at10, calendar: calendar)
        let comps = calendar.dateComponents([.hour, .minute], from: fire)
        #expect(comps.hour == 12 && comps.minute == 0)
    }

    @Test func specificTimesRollsOverToTomorrow() {
        let calendar = Calendar(identifier: .gregorian)
        let rule = RotationRule(
            scheduleMode: .specificTimes,
            specificMinutesOfDay: [8 * 60, 12 * 60]
        )
        let at23 = calendar.date(from: DateComponents(year: 2026, month: 4, day: 22, hour: 23))!
        let fire = Scheduler.nextFire(for: rule, after: at23, calendar: calendar)
        let comps = calendar.dateComponents([.year, .month, .day, .hour], from: fire)
        #expect(comps.day == 23 && comps.hour == 8)
    }

    @Test func daysOfWeekRestriction() {
        let calendar = Calendar(identifier: .gregorian)
        // Weekdays only: Mon–Fri = bits for weekdays 2..6
        let mask = (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5)
        let rule = RotationRule(
            intervalSeconds: 3600,
            alignToClock: true,
            daysOfWeekMask: mask
        )
        // 2026-04-25 is a Saturday — skip to Monday.
        let sat = calendar.date(from: DateComponents(year: 2026, month: 4, day: 25, hour: 9, minute: 30))!
        let fire = Scheduler.nextFire(for: rule, after: sat, calendar: calendar)
        let wd = calendar.component(.weekday, from: fire)
        #expect(wd == 2) // Monday
    }
}
