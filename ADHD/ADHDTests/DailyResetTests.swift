import Testing
import Foundation
import SwiftData
@testable import ADHD

// MARK: - TaskManager.checkAndResetDailyTasks Tests
/// in-memory ModelContainer + 주입된 UserDefaults/now로 날짜 경계 로직을 검증한다.
@MainActor
struct DailyResetTests {

    private final class FailingSaveManager: TaskManager {
        var shouldFail = true
        override func safeSave() -> Bool {
            shouldFail ? false : super.safeSave()
        }
    }

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
        AccountPreferences.activate(for: UUID(), defaults: defaults)
        return defaults
    }

    @Test func sameDayIsNoOp() throws {
        let manager = try makeManager()
        let defaults = freshDefaults("test.dailyreset.sameday")
        let now = date(2026, 7, 8)
        AccountPreferences.set(now, for: .lastDailyResetDate, defaults: defaults)

        let routine = AppTask(task: "루틴", category: "Routine", isCompleted: true)
        manager.modelContext!.insert(routine)

        manager.checkAndResetDailyTasks(now: now, defaults: defaults)
        #expect(routine.isCompleted == true)   // 같은 날 재호출 → 리셋 없음
    }

    @Test func nextDayResetsCompletionAndRecordsYesterday() throws {
        let manager = try makeManager()
        let defaults = freshDefaults("test.dailyreset.nextday")
        // 화(7/7) → 수(7/8): 같은 ISO 주 내 하루 경과
        AccountPreferences.set(date(2026, 7, 7), for: .lastDailyResetDate, defaults: defaults)

        let routine = AppTask(task: "루틴", category: "Routine", isCompleted: true)
        manager.modelContext!.insert(routine)

        manager.checkAndResetDailyTasks(now: date(2026, 7, 8), defaults: defaults)

        #expect(routine.isCompleted == false)                            // 새 날 → 완료 리셋
        #expect(routine.weeklyCompletions[1]) // Tuesday is index 1, not Wednesday.
        #expect(routine.weeklyCompletions.filter { $0 }.count == 1)      // 어제 요일에 완료 기록
    }

    @Test func weekBoundaryClearsWeeklyCompletions() throws {
        let manager = try makeManager()
        let defaults = freshDefaults("test.dailyreset.weekboundary")
        // 일(7/5) → 월(7/6): ISO 주 경계(월요일 시작)를 넘음
        AccountPreferences.set(date(2026, 7, 5), for: .lastDailyResetDate, defaults: defaults)

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
        AccountPreferences.set(date(2026, 7, 7), for: .lastDailyResetDate, defaults: defaults)

        let routine = AppTask(task: "루틴", category: "Routine", isCompleted: true)
        manager.modelContext!.insert(routine)

        let now = date(2026, 7, 8)
        manager.checkAndResetDailyTasks(now: now, defaults: defaults)
        routine.isCompleted = true   // 사용자가 오늘 다시 완료
        manager.checkAndResetDailyTasks(now: now, defaults: defaults)

        #expect(routine.isCompleted == true)   // 같은 날 2번째 호출은 no-op
    }
    @Test func anotherAccountsResetDoesNotSkipThisAccountsRoutines() throws {
        let first = try makeManager(), second = try makeManager()
        let defaults = freshDefaults("test.dailyreset.accounts")
        let firstID = UUID(), secondID = UUID()
        let now = date(2026, 7, 8)
        AccountPreferences.activate(for: firstID, defaults: defaults)
        first.checkAndResetDailyTasks(now: now, defaults: defaults)
        let routine = AppTask(task: "다른 계정 루틴", category: "Routine", isCompleted: true)
        second.modelContext!.insert(routine)
        AccountPreferences.activate(for: secondID, defaults: defaults)
        AccountPreferences.set(date(2026, 7, 7), for: .lastDailyResetDate, defaults: defaults)
        second.checkAndResetDailyTasks(now: now, defaults: defaults)
        #expect(!routine.isCompleted)
        #expect(routine.weeklyCompletions[1])
        AccountPreferences.activate(for: firstID, defaults: defaults)
        #expect(AccountPreferences.date(.lastDailyResetDate, defaults: defaults) == now)
    }

    @Test func failedSavePreservesCompletionAndResetDateForRetry() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: AppTask.self, configurations: config)
        let manager = FailingSaveManager()
        manager.modelContext = ModelContext(container)
        let defaults = freshDefaults("test.dailyreset.savefailure")
        let yesterday = date(2026, 7, 7), today = date(2026, 7, 8)
        AccountPreferences.set(yesterday, for: .lastDailyResetDate, defaults: defaults)
        let routine = AppTask(task: "완료 기록 보존", category: "Routine", isCompleted: true)
        manager.modelContext!.insert(routine)
        try manager.modelContext!.save()

        manager.checkAndResetDailyTasks(now: today, defaults: defaults)
        #expect(routine.isCompleted)
        #expect(routine.weeklyCompletions.allSatisfy { !$0 })
        #expect(AccountPreferences.date(.lastDailyResetDate, defaults: defaults) == yesterday)

        manager.shouldFail = false
        manager.checkAndResetDailyTasks(now: today, defaults: defaults)
        #expect(!routine.isCompleted)
        #expect(routine.weeklyCompletions[1])
        #expect(AccountPreferences.date(.lastDailyResetDate, defaults: defaults) == today)
    }

}
