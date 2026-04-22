import Testing
import Foundation
@testable import paperpaper

struct SchedulerTests {
    @Test func offModeUsesIntervalSeconds() {
        let rule = RotationRule(intervalSeconds: 3600, dayNightMode: .off)
        #expect(Scheduler.nextIntervalSeconds(for: rule) == 3600)
    }

    @Test func separateIntervalsUsesNightAtNight() {
        let rule = RotationRule(
            intervalSeconds: 600,
            nightIntervalSeconds: 7200,
            dayNightMode: .separateIntervals,
            dayStartHour: 7,
            nightStartHour: 20
        )
        let calendar = Calendar(identifier: .gregorian)
        let components = DateComponents(year: 2026, month: 4, day: 22, hour: 22)
        let nightDate = calendar.date(from: components)!
        #expect(Scheduler.nextIntervalSeconds(for: rule, at: nightDate, calendar: calendar) == 7200)
    }

    @Test func separateIntervalsUsesDayAtDay() {
        let rule = RotationRule(
            intervalSeconds: 600,
            nightIntervalSeconds: 7200,
            dayNightMode: .separateIntervals,
            dayStartHour: 7,
            nightStartHour: 20
        )
        let calendar = Calendar(identifier: .gregorian)
        let components = DateComponents(year: 2026, month: 4, day: 22, hour: 10)
        let dayDate = calendar.date(from: components)!
        #expect(Scheduler.nextIntervalSeconds(for: rule, at: dayDate, calendar: calendar) == 600)
    }

    @Test func minimumFloorFiveSeconds() {
        let rule = RotationRule(intervalSeconds: 1, dayNightMode: .off)
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
}
