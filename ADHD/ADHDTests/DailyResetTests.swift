import Testing
import Foundation
import SwiftData
@testable import ADHD

// MARK: - TaskManager.checkAndResetDailyTasks Tests
/// in-memory ModelContainer + 주입된 UserDefaults/now로 날짜 경계 로직을 검증한다.
@MainActor
struct DailyResetTests {

    private let cal = Calendar.current

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func makeManager() throws -> TaskManager {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: AppTask.self, configurations: config)
        let manager = TaskManager()
        manager.modelContext = ModelContext(container)
        return manager
    }

    private func freshDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func sameDayIsNoOp() throws {
        let manager = try makeManager()
        let defaults = freshDefaults("test.dailyreset.sameday")
        let now = date(2026, 7, 8)
        defaults.set(now, forKey: "lastResetDate")

        let routine = AppTask(task: "루틴", category: "Routine", isCompleted: true)
        manager.modelContext!.insert(routine)

        manager.checkAndResetDailyTasks(now: now, defaults: defaults)
        #expect(routine.isCompleted == true)   // 같은 날 재호출 → 리셋 없음
    }

    @Test func nextDayResetsCompletionAndRecordsYesterday() throws {
        let manager = try makeManager()
        let defaults = freshDefaults("test.dailyreset.nextday")
        // 화(7/7) → 수(7/8): 같은 ISO 주 내 하루 경과
        defaults.set(date(2026, 7, 7), forKey: "lastResetDate")

        let routine = AppTask(task: "루틴", category: "Routine", isCompleted: true)
        manager.modelContext!.insert(routine)

        manager.checkAndResetDailyTasks(now: date(2026, 7, 8), defaults: defaults)

        #expect(routine.isCompleted == false)                            // 새 날 → 완료 리셋
        #expect(routine.weeklyCompletions.filter { $0 }.count == 1)      // 어제 요일에 완료 기록
    }

    @Test func weekBoundaryClearsWeeklyCompletions() throws {
        let manager = try makeManager()
        let defaults = freshDefaults("test.dailyreset.weekboundary")
        // 일(7/5) → 월(7/6): ISO 주 경계(월요일 시작)를 넘음
        defaults.set(date(2026, 7, 5), forKey: "lastResetDate")

        let routine = AppTask(task: "루틴", category: "Routine", isCompleted: true)
        routine.weeklyCompletions = Array(repeating: true, count: 7)
        manager.modelContext!.insert(routine)

        manager.checkAndResetDailyTasks(now: date(2026, 7, 6), defaults: defaults)

        #expect(routine.isCompleted == false)
        #expect(routine.weeklyCompletions.allSatisfy { !$0 })            // 주 경계 → 전체 초기화
    }

    @Test func secondCallOnSameDayDoesNotDoubleReset() throws {
        let manager = try makeManager()
        let defaults = freshDefaults("test.dailyreset.idempotent")
        defaults.set(date(2026, 7, 7), forKey: "lastResetDate")

        let routine = AppTask(task: "루틴", category: "Routine", isCompleted: true)
        manager.modelContext!.insert(routine)

        let now = date(2026, 7, 8)
        manager.checkAndResetDailyTasks(now: now, defaults: defaults)
        routine.isCompleted = true   // 사용자가 오늘 다시 완료
        manager.checkAndResetDailyTasks(now: now, defaults: defaults)

        #expect(routine.isCompleted == true)   // 같은 날 2번째 호출은 no-op
    }
}
