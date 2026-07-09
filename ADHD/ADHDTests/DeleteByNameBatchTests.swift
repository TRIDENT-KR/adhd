import Testing
import Foundation
import SwiftData
@testable import ADHD

// MARK: - TaskManager.deleteByNameBatch Tests
/// 이름 기반 배치 삭제의 매칭 전략(정확 > 부분 2자+)과 필터 검증
@MainActor
struct DeleteByNameBatchTests {

    private func makeManager() throws -> TaskManager {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: AppTask.self, configurations: config)
        let manager = TaskManager()
        manager.modelContext = ModelContext(container)
        return manager
    }

    private func seed(_ manager: TaskManager, _ tasks: [AppTask]) {
        for task in tasks {
            manager.modelContext!.insert(task)
        }
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d))!
    }

    @Test func exactMatchTakesPriorityOverPartial() throws {
        let manager = try makeManager()
        seed(manager, [
            AppTask(task: "운동", category: "Routine"),
            AppTask(task: "운동하기", category: "Routine"),
        ])

        let deleted = manager.deleteByNameBatch(containing: "운동")

        #expect(deleted.count == 1)              // 정확 매칭이 있으면 부분 매칭은 무시
        #expect(deleted.first?.task == "운동")
    }

    @Test func partialMatchWhenNoExactMatch() throws {
        let manager = try makeManager()
        seed(manager, [AppTask(task: "운동하기", category: "Routine")])

        let deleted = manager.deleteByNameBatch(containing: "운동")

        #expect(deleted.count == 1)
        #expect(deleted.first?.task == "운동하기")
    }

    @Test func singleCharacterQueryIsIgnored() throws {
        let manager = try makeManager()
        seed(manager, [AppTask(task: "운동", category: "Routine")])

        let deleted = manager.deleteByNameBatch(containing: "운")

        #expect(deleted.isEmpty)                 // 1글자 검색어 안전장치
    }

    @Test func categoryFilterLimitsScope() throws {
        let manager = try makeManager()
        seed(manager, [
            AppTask(task: "정리", category: "Routine"),
            AppTask(task: "정리", date: date(2026, 7, 9), category: "Appointment"),
        ])

        let deleted = manager.deleteByNameBatch(containing: "정리", category: "Routine")

        #expect(deleted.count == 1)
        #expect(deleted.first?.category == "Routine")
    }

    @Test func dateFilterMatchesSameDayOnly() throws {
        let manager = try makeManager()
        seed(manager, [
            AppTask(task: "회의", date: date(2026, 7, 9), category: "Appointment"),
            AppTask(task: "회의", date: date(2026, 7, 10), category: "Appointment"),
        ])

        let deleted = manager.deleteByNameBatch(containing: "회의", dateString: "2026-07-09")

        #expect(deleted.count == 1)
        #expect(Calendar.current.isDate(deleted.first!.date!, inSameDayAs: date(2026, 7, 9)))
    }

    @Test func allKeywordBypassesFilters() throws {
        let manager = try makeManager()
        seed(manager, [
            AppTask(task: "청소", category: "Routine"),
            AppTask(task: "청소", date: date(2026, 7, 9), category: "Appointment"),
        ])

        let deleted = manager.deleteByNameBatch(containing: "청소", category: "all", dateString: "all")

        #expect(deleted.count == 2)              // "all"은 카테고리·날짜 필터 통과
    }
}
