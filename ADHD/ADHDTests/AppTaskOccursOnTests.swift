import Testing
import Foundation
@testable import ADHD

// MARK: - AppTask.occursOn Tests
/// occursOn(_:)은 탭 필터·위젯 스냅샷·clearAllTasks의 단일 진리원이다.
struct AppTaskOccursOnTests {

    private let cal: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private func date(
        _ y: Int,
        _ m: Int,
        _ d: Int,
        _ hour: Int = 0,
        _ minute: Int = 0,
        calendar: Calendar? = nil
    ) -> Date {
        let calendar = calendar ?? cal
        return calendar.date(from: DateComponents(
            year: y,
            month: m,
            day: d,
            hour: hour,
            minute: minute
        ))!
    }

    private func day(_ base: Date, plus days: Int) -> Date {
        cal.date(byAdding: .day, value: days, to: base)!
    }

    // MARK: Routine

    @Test func routineWithoutDateOccursEveryDay() {
        let task = AppTask(task: "물 마시기", category: "Routine")
        #expect(task.occursOn(date(2026, 7, 9), calendar: cal))
        #expect(task.occursOn(date(2027, 1, 1), calendar: cal))
    }

    @Test func routineWithDateOccursOnlyThatDay() {
        let d = date(2026, 7, 9)
        let task = AppTask(task: "스트레칭", date: d, category: "Routine")
        #expect(task.occursOn(d, calendar: cal))
        #expect(!task.occursOn(day(d, plus: 1), calendar: cal))
    }

    // MARK: Appointment 일회성

    @Test func oneTimeAppointmentOccursOnlyOnItsDay() {
        let d = date(2026, 7, 10)
        let task = AppTask(task: "치과", date: d, category: "Appointment")
        #expect(task.occursOn(d, calendar: cal))
        #expect(!task.occursOn(day(d, plus: 1), calendar: cal))
        #expect(!task.occursOn(day(d, plus: -1), calendar: cal))
    }

    // MARK: Weekly / Biweekly

    @Test func weeklyOccursOnSameWeekdayEveryWeek() {
        let start = date(2026, 7, 8)
        let task = AppTask(task: "주간 회의", date: start, category: "Appointment", recurrenceRule: "weekly")
        #expect(task.occursOn(start, calendar: cal))
        #expect(task.occursOn(day(start, plus: 7), calendar: cal))
        #expect(task.occursOn(day(start, plus: 14), calendar: cal))
        #expect(!task.occursOn(day(start, plus: 1), calendar: cal))
    }

    @Test func weeklyDoesNotOccurBeforeStartDate() {
        let start = date(2026, 7, 8)
        let task = AppTask(task: "주간 회의", date: start, category: "Appointment", recurrenceRule: "weekly")
        #expect(!task.occursOn(day(start, plus: -7), calendar: cal))
    }

    @Test func biweeklyOccursEveryOtherWeek() {
        let start = date(2026, 7, 8)
        let task = AppTask(task: "격주 점검", date: start, category: "Appointment", recurrenceRule: "biweekly")
        #expect(task.occursOn(start, calendar: cal))
        #expect(task.occursOn(day(start, plus: 14), calendar: cal))
        #expect(task.occursOn(day(start, plus: 28), calendar: cal))
        #expect(!task.occursOn(day(start, plus: 7), calendar: cal))
        #expect(!task.occursOn(day(start, plus: 21), calendar: cal))
    }

    // MARK: Monthly — 말일 보정

    @Test func monthlyStartingOn31stFallsBackToLastDayOfShortMonths() {
        let start = date(2026, 1, 31)
        let task = AppTask(task: "월세", date: start, category: "Appointment", recurrenceRule: "monthly")
        // 2026년 2월은 28일까지 → 말일(28일)에 발생
        #expect(task.occursOn(date(2026, 2, 28), calendar: cal))
        #expect(!task.occursOn(date(2026, 2, 27), calendar: cal))
        // 31일이 있는 달은 그대로 31일
        #expect(task.occursOn(date(2026, 3, 31), calendar: cal))
    }

    // MARK: Yearly

    @Test func yearlyOccursOnSameMonthAndDay() {
        let start = date(2026, 7, 9)
        let task = AppTask(task: "기념일", date: start, category: "Appointment", recurrenceRule: "yearly")
        #expect(task.occursOn(date(2027, 7, 9), calendar: cal))
        #expect(!task.occursOn(date(2027, 7, 10), calendar: cal))
    }

    @Test func yearlyFebruary29UsesFebruary28ThenReturnsToLeapDay() {
        let start = date(2024, 2, 29)
        let task = AppTask(task: "윤년 기념일", date: start, category: "Appointment", recurrenceRule: "yearly")

        #expect(task.occursOn(date(2025, 2, 28), calendar: cal))
        #expect(!task.occursOn(date(2025, 3, 1), calendar: cal))
        #expect(task.occursOn(date(2028, 2, 29), calendar: cal))
        #expect(!task.occursOn(date(2028, 2, 28), calendar: cal))
    }

    // MARK: Next one-shot schedule

    @Test func biweeklyNextScheduleRemainsAnchoredAfterLateRearm() {
        let anchor = date(2026, 7, 8)
        let now = date(2026, 7, 22, 10)
        let next = RecurrenceEngine.nextScheduledDate(
            after: now,
            anchor: anchor,
            rule: "biweekly",
            hour: 9,
            minute: 0,
            calendar: cal
        )

        #expect(next == date(2026, 8, 5, 9))
    }

    @Test func monthlyNextScheduleUsesClampedDayAndLeadTime() {
        let next = RecurrenceEngine.nextScheduledDate(
            after: date(2026, 2, 28, 8),
            anchor: date(2026, 1, 31),
            rule: "monthly",
            hour: 9,
            minute: 0,
            leadMinutes: 30,
            calendar: cal
        )

        #expect(next == date(2026, 2, 28, 8, 30))
    }

    @Test func yearlyNextScheduleClampsFebruary29WithoutChangingAnchor() {
        let next = RecurrenceEngine.nextScheduledDate(
            after: date(2025, 2, 27, 12),
            anchor: date(2024, 2, 29),
            rule: "yearly",
            hour: 9,
            minute: 0,
            calendar: cal
        )

        #expect(next == date(2025, 2, 28, 9))
    }

    @Test func dstGapMovesToNextValidLocalTime() {
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.locale = Locale(identifier: "en_US_POSIX")
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        let next = RecurrenceEngine.nextScheduledDate(
            after: date(2026, 3, 8, calendar: losAngeles),
            anchor: date(2026, 2, 8, calendar: losAngeles),
            rule: "monthly",
            hour: 2,
            minute: 30,
            calendar: losAngeles
        )
        let parts = next.map {
            losAngeles.dateComponents([.year, .month, .day, .hour, .minute], from: $0)
        }

        #expect(parts?.year == 2026)
        #expect(parts?.month == 3)
        #expect(parts?.day == 8)
        #expect(parts?.hour == 3)
        #expect(parts?.minute == 0)
    }

    @Test func dstOverlapUsesFirstLocalOccurrenceOnly() {
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.locale = Locale(identifier: "en_US_POSIX")
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        let next = RecurrenceEngine.nextScheduledDate(
            after: date(2026, 11, 1, calendar: losAngeles),
            anchor: date(2026, 10, 1, calendar: losAngeles),
            rule: "monthly",
            hour: 1,
            minute: 30,
            calendar: losAngeles
        )

        #expect(next != nil)
        if let next {
            #expect(losAngeles.component(.hour, from: next) == 1)
            #expect(losAngeles.component(.minute, from: next) == 30)
            #expect(losAngeles.timeZone.secondsFromGMT(for: next) == -7 * 60 * 60)
        }
    }
}
