import Testing
import Foundation
@testable import ADHD

// MARK: - AppTask.occursOn Tests
/// occursOn(_:)은 탭 필터·위젯 스냅샷·clearAllTasks의 단일 진리원이다.
struct AppTaskOccursOnTests {

    private let cal = Calendar.current

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func day(_ base: Date, plus days: Int) -> Date {
        cal.date(byAdding: .day, value: days, to: base)!
    }

    // MARK: Routine

    @Test func routineWithoutDateOccursEveryDay() {
        let task = AppTask(task: "물 마시기", category: "Routine")
        #expect(task.occursOn(date(2026, 7, 9)))
        #expect(task.occursOn(date(2027, 1, 1)))
    }

    @Test func routineWithDateOccursOnlyThatDay() {
        let d = date(2026, 7, 9)
        let task = AppTask(task: "스트레칭", date: d, category: "Routine")
        #expect(task.occursOn(d))
        #expect(!task.occursOn(day(d, plus: 1)))
    }

    // MARK: Appointment 일회성

    @Test func oneTimeAppointmentOccursOnlyOnItsDay() {
        let d = date(2026, 7, 10)
        let task = AppTask(task: "치과", date: d, category: "Appointment")
        #expect(task.occursOn(d))
        #expect(!task.occursOn(day(d, plus: 1)))
        #expect(!task.occursOn(day(d, plus: -1)))
    }

    // MARK: Weekly / Biweekly

    @Test func weeklyOccursOnSameWeekdayEveryWeek() {
        let start = date(2026, 7, 8)
        let task = AppTask(task: "주간 회의", date: start, category: "Appointment", recurrenceRule: "weekly")
        #expect(task.occursOn(start))
        #expect(task.occursOn(day(start, plus: 7)))
        #expect(task.occursOn(day(start, plus: 14)))
        #expect(!task.occursOn(day(start, plus: 1)))
    }

    @Test func weeklyDoesNotOccurBeforeStartDate() {
        let start = date(2026, 7, 8)
        let task = AppTask(task: "주간 회의", date: start, category: "Appointment", recurrenceRule: "weekly")
        #expect(!task.occursOn(day(start, plus: -7)))
    }

    @Test func biweeklyOccursEveryOtherWeek() {
        let start = date(2026, 7, 8)
        let task = AppTask(task: "격주 점검", date: start, category: "Appointment", recurrenceRule: "biweekly")
        #expect(task.occursOn(start))
        #expect(task.occursOn(day(start, plus: 14)))
        #expect(!task.occursOn(day(start, plus: 7)))
    }

    // MARK: Monthly — 말일 보정

    @Test func monthlyStartingOn31stFallsBackToLastDayOfShortMonths() {
        let start = date(2026, 1, 31)
        let task = AppTask(task: "월세", date: start, category: "Appointment", recurrenceRule: "monthly")
        // 2026년 2월은 28일까지 → 말일(28일)에 발생
        #expect(task.occursOn(date(2026, 2, 28)))
        #expect(!task.occursOn(date(2026, 2, 27)))
        // 31일이 있는 달은 그대로 31일
        #expect(task.occursOn(date(2026, 3, 31)))
    }

    // MARK: Yearly

    @Test func yearlyOccursOnSameMonthAndDay() {
        let start = date(2026, 7, 9)
        let task = AppTask(task: "기념일", date: start, category: "Appointment", recurrenceRule: "yearly")
        #expect(task.occursOn(date(2027, 7, 9)))
        #expect(!task.occursOn(date(2027, 7, 10)))
    }
}
