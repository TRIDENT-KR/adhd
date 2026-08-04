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

    @Test func destructiveLLMCommandIsBlockedUntilExplicitlyConfirmed() throws {
        let manager = try makeManager()
        seed(manager, [AppTask(task: "운동", category: "Routine")])
        let command = LLMFunctionCall.deleteSpecificTask(
            DeleteTaskParams(target_task_name: "운동", target_category: nil, target_date: nil)
        )

        #expect(!manager.execute(llmCalls: [command]))
        #expect(try manager.modelContext!.fetch(FetchDescriptor<AppTask>()).count == 1)

        #expect(manager.execute(llmCalls: [command], explicitlyConfirmed: true))
        #expect(try manager.modelContext!.fetch(FetchDescriptor<AppTask>()).isEmpty)
    }

    @Test func unknownLLMCommandIsRejected() throws {
        let manager = try makeManager()

        #expect(!manager.execute(llmCalls: [.unknown("unsupported")]))
    }

    @Test func malformedDeleteDateCannotBroadenScope() throws {
        let manager = try makeManager()
        seed(manager, [AppTask(task: "운동", category: "Routine")])
        let command = LLMFunctionCall.deleteSpecificTask(
            DeleteTaskParams(
                target_task_name: "운동",
                target_category: nil,
                target_date: "not-a-date"
            )
        )

        #expect(!manager.execute(llmCalls: [command], explicitlyConfirmed: true))
        #expect(try manager.modelContext!.fetch(FetchDescriptor<AppTask>()).count == 1)
    }

    @Test func partialSuccessKeepsFailureAndCreatesOneUndoEntry() throws {
        let manager = try makeManager()
        seed(manager, [AppTask(task: "기존 일정", category: "Routine")])

        let calls = [
            PendingLLMCall(call: .addSingleTask(AddSingleTaskParams(
                task_name: "새 일정",
                time: "09:00",
                date: nil,
                category: "Routine",
                recurrence: nil,
                urgency: nil
            ))),
            PendingLLMCall(call: .updateTask(UpdateTaskParams(
                target_task_name: "없는 일정",
                new_task_name: "바뀐 일정",
                new_time: nil,
                new_date: nil,
                new_category: nil,
                new_recurrence: nil
            ))),
        ]
        let prepared = manager.preparePendingCalls(calls)

        let result = manager.executeDetailed(
            pendingCalls: prepared,
            explicitlyConfirmed: true
        )

        #expect(result.hasAnySuccess)
        #expect(!result.allSucceeded)
        #expect(result.remainingCalls.count == 1)
        #expect(result.items.last?.issue == .noMatchingTarget)
        #expect(manager.undoStack.count == 1)
        #expect(try manager.modelContext!.fetch(FetchDescriptor<AppTask>()).contains {
            $0.task == "새 일정"
        })

        manager.undo()
        let afterUndo = try manager.modelContext!.fetch(FetchDescriptor<AppTask>())
        #expect(afterUndo.map(\.task) == ["기존 일정"])
    }

    @Test func successfulApprovalUsesOneGroupedUndo() throws {
        let manager = try makeManager()
        let existing = AppTask(task: "약 먹기", category: "Routine")
        seed(manager, [existing])

        let calls = [
            PendingLLMCall(call: .addSingleTask(AddSingleTaskParams(
                task_name: "물 마시기",
                time: "10:00",
                date: nil,
                category: "Routine",
                recurrence: nil,
                urgency: nil
            ))),
            PendingLLMCall(call: .markTaskComplete(
                MarkTaskCompleteParams(target_task_name: "약 먹기")
            )),
        ]

        let result = manager.executeDetailed(
            pendingCalls: manager.preparePendingCalls(calls),
            explicitlyConfirmed: true
        )

        #expect(result.allSucceeded)
        #expect(existing.isCompleted)
        #expect(manager.undoStack.count == 1)

        manager.undo()
        let afterUndo = try manager.modelContext!.fetch(FetchDescriptor<AppTask>())
        #expect(afterUndo.count == 1)
        #expect(afterUndo.first?.id == existing.id)
        #expect(afterUndo.first?.isCompleted == false)
    }

    @Test func stalePreparedUpdateRequiresFreshConfirmation() throws {
        let manager = try makeManager()
        let existing = AppTask(task: "회의", time: "09:00", category: "Routine")
        seed(manager, [existing])

        let call = PendingLLMCall(call: .updateTask(UpdateTaskParams(
            target_task_name: "회의",
            new_task_name: nil,
            new_time: "10:00",
            new_date: nil,
            new_category: nil,
            new_recurrence: nil
        )))
        let prepared = manager.preparePendingCalls([call])

        // 승인 화면이 열린 뒤 사용자가 위젯/다른 UI에서 직접 수정한 상황입니다.
        existing.time = "11:00"
        try manager.modelContext!.save()

        let firstAttempt = manager.executeDetailed(
            pendingCalls: prepared,
            explicitlyConfirmed: true
        )

        #expect(!firstAttempt.hasAnySuccess)
        #expect(firstAttempt.items.first?.issue == .staleTarget)
        #expect(firstAttempt.remainingCalls.first?.requiresReconfirmation == true)
        #expect(existing.time == "11:00")

        let secondAttempt = manager.executeDetailed(
            pendingCalls: firstAttempt.remainingCalls,
            explicitlyConfirmed: true
        )
        #expect(secondAttempt.allSucceeded)
        #expect(existing.time == "10:00")
    }

    @Test func approvedDeleteIDsDoNotExpandToNewMatches() throws {
        let manager = try makeManager()
        let approvedTarget = AppTask(task: "회의 준비", category: "Routine")
        seed(manager, [approvedTarget])

        let call = PendingLLMCall(call: .deleteSpecificTask(DeleteTaskParams(
            target_task_name: "회의",
            target_category: nil,
            target_date: nil
        )))
        let prepared = manager.preparePendingCalls([call])
        #expect(prepared.first?.targetSnapshots?.map(\.id) == [approvedTarget.id])

        let laterMatch = AppTask(task: "회의 정리", category: "Routine")
        manager.modelContext!.insert(laterMatch)
        try manager.modelContext!.save()

        let result = manager.executeDetailed(
            pendingCalls: prepared,
            explicitlyConfirmed: true
        )
        let remaining = try manager.modelContext!.fetch(FetchDescriptor<AppTask>())

        #expect(result.allSucceeded)
        #expect(remaining.map(\.id) == [laterMatch.id])
    }
}
