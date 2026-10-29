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
                time: "09:00 AM",
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
                time: "10:00 AM",
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
            new_time: "10:00 AM",
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
        #expect(existing.time == "10:00 AM")
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

// MARK: - 같은 이름 대상 고르기
/// 같은 이름이 여럿이면 미완료 → 오늘 이후 가장 가까운 일정 → 가장 최근 지난 일정 순으로 고릅니다.
@MainActor
struct BestMatchOrderingTests {

    private let calendar = Calendar.current

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 12))!
    }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
    }

    private func pick(_ name: String, _ tasks: [AppTask]) -> AppTask? {
        TaskManager.bestMatch(name: name, in: tasks, now: now, calendar: calendar)
    }

    @Test func prefersIncompleteOverCompleted() {
        let done = AppTask(task: "회의", date: day(0), category: "Appointment", isCompleted: true)
        let open = AppTask(task: "회의", date: day(3), category: "Appointment")

        #expect(pick("회의", [done, open])?.id == open.id)
        #expect(pick("회의", [open, done])?.id == open.id)
    }

    @Test func prefersNearestUpcomingOverPastAndLater() {
        let past = AppTask(task: "회의", date: day(-1), category: "Appointment")
        let nextWeek = AppTask(task: "회의", date: day(7), category: "Appointment")
        let tomorrow = AppTask(task: "회의", date: day(1), category: "Appointment")

        #expect(pick("회의", [past, nextWeek, tomorrow])?.id == tomorrow.id)
        #expect(pick("회의", [tomorrow, past, nextWeek])?.id == tomorrow.id)
    }

    @Test func fallsBackToMostRecentPast() {
        let lastMonth = AppTask(task: "회의", date: day(-30), category: "Appointment")
        let yesterday = AppTask(task: "회의", date: day(-1), category: "Appointment")

        #expect(pick("회의", [lastMonth, yesterday])?.id == yesterday.id)
    }

    @Test func recurringSeriesCountsByNextOccurrence() {
        // 지난주에 시작한 매주 반복은 다음 발생일(6일 뒤)로 비교합니다.
        let weekly = AppTask(task: "스터디", date: day(-1), category: "Appointment", recurrenceRule: "weekly")
        let inTwoDays = AppTask(task: "스터디", date: day(2), category: "Appointment")
        let inTenDays = AppTask(task: "스터디", date: day(10), category: "Appointment")

        #expect(pick("스터디", [weekly, inTenDays])?.id == weekly.id)
        #expect(pick("스터디", [weekly, inTwoDays])?.id == inTwoDays.id)
    }

    @Test func dailyRoutineCountsAsToday() {
        let routine = AppTask(task: "약 먹기", time: "09:00 PM", category: "Routine")
        let tomorrow = AppTask(task: "약 먹기", date: day(1), category: "Appointment")

        #expect(pick("약 먹기", [tomorrow, routine])?.id == routine.id)
    }

    @Test func exactNameStillBeatsPartialName() {
        let partial = AppTask(task: "팀 회의", date: day(0), category: "Appointment")
        let exact = AppTask(task: "회의", date: day(5), category: "Appointment")

        #expect(pick("회의", [partial, exact])?.id == exact.id)
    }

    @Test func tieBreakIsDeterministic() {
        let first = AppTask(task: "회의", time: "09:00 AM", date: day(1), category: "Appointment")
        let second = AppTask(task: "회의", time: "09:00 AM", date: day(1), category: "Appointment")
        let expected = first.id.uuidString < second.id.uuidString ? first : second

        #expect(pick("회의", [first, second])?.id == expected.id)
        #expect(pick("회의", [second, first])?.id == expected.id)
    }

    @Test func updatePreviewTargetsIncompleteUpcomingTask() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: AppTask.self, configurations: config)
        let manager = TaskManager()
        manager.modelContext = ModelContext(container)

        let today = Calendar.current.startOfDay(for: Date())
        let pastDone = AppTask(
            task: "회의",
            date: Calendar.current.date(byAdding: .day, value: -2, to: today),
            category: "Appointment",
            isCompleted: true
        )
        let upcoming = AppTask(
            task: "회의",
            date: Calendar.current.date(byAdding: .day, value: 1, to: today),
            category: "Appointment"
        )
        manager.modelContext!.insert(pastDone)
        manager.modelContext!.insert(upcoming)

        let prepared = manager.preparePendingCalls([
            PendingLLMCall(call: .updateTask(UpdateTaskParams(
                target_task_name: "회의",
                new_task_name: nil,
                new_time: "04:00 PM",
                new_date: nil,
                new_category: nil,
                new_recurrence: nil
            ))),
        ])

        #expect(prepared.first?.targetSnapshots?.map(\.id) == [upcoming.id])
    }
}

// MARK: - 날짜를 정한 일괄 삭제
/// "오늘 일정 다 지워줘"는 그날 하루짜리 일정만 지우고, 반복 시리즈와 매일 루틴은 남깁니다.
@MainActor
struct DateScopedClearTests {

    private let calendar = Calendar.current

    private var today: Date { calendar.startOfDay(for: Date()) }

    private var todayString: String { StoredTaskFormat.date.string(from: today) }

    private func makeManager() throws -> TaskManager {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: AppTask.self, configurations: config)
        let manager = TaskManager()
        manager.modelContext = ModelContext(container)
        return manager
    }

    @Test func dateScopedClearSkipsRecurringAndDailyRoutines() {
        let oneOff = AppTask(task: "치과", date: today, category: "Appointment")
        let weekly = AppTask(task: "스터디", date: today, category: "Appointment", recurrenceRule: "weekly")
        let daily = AppTask(task: "약 먹기", category: "Routine")
        let datedRoutine = AppTask(task: "대청소", date: today, category: "Routine")
        let otherDay = AppTask(
            task: "회의",
            date: calendar.date(byAdding: .day, value: 1, to: today),
            category: "Appointment"
        )
        let tasks = [oneOff, weekly, daily, datedRoutine, otherDay]

        let defaultScope = TaskManager.clearTargets(
            for: ClearTasksParams(target_category: nil, target_date: todayString),
            in: tasks
        )
        #expect(defaultScope.map(\.id) == [oneOff.id])

        let allCategories = TaskManager.clearTargets(
            for: ClearTasksParams(target_category: "all", target_date: todayString),
            in: tasks
        )
        #expect(Set(allCategories.map(\.id)) == [oneOff.id, datedRoutine.id])
    }

    @Test func clearEverythingStillIncludesSeriesAndRoutines() {
        let weekly = AppTask(task: "스터디", date: today, category: "Appointment", recurrenceRule: "weekly")
        let daily = AppTask(task: "약 먹기", category: "Routine")

        let targets = TaskManager.clearTargets(
            for: ClearTasksParams(target_category: "all", target_date: "all"),
            in: [weekly, daily]
        )
        #expect(targets.count == 2)
    }

    @Test func clearingTodayKeepsWeeklySeriesInStore() throws {
        let manager = try makeManager()
        let oneOff = AppTask(task: "치과", date: today, category: "Appointment")
        let weekly = AppTask(task: "스터디", date: today, category: "Appointment", recurrenceRule: "weekly")
        manager.modelContext!.insert(oneOff)
        manager.modelContext!.insert(weekly)

        let prepared = manager.preparePendingCalls([
            PendingLLMCall(call: .clearAllTasks(
                ClearTasksParams(target_category: nil, target_date: todayString)
            )),
        ])
        #expect(prepared.first?.targetNamesSummary == "치과")

        let result = manager.executeDetailed(pendingCalls: prepared, explicitlyConfirmed: true)
        let remaining = try manager.modelContext!.fetch(FetchDescriptor<AppTask>())

        #expect(result.allSucceeded)
        #expect(remaining.map(\.id) == [weekly.id])
    }
}

// MARK: - 되묻기·잡담 실행 결과
/// 되묻기는 저장이 아니므로 성공으로 세지 않고, 되돌리기 스낵바도 건드리지 않습니다.
@MainActor
struct FeedbackOnlyExecutionTests {

    private func makeManager() throws -> TaskManager {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: AppTask.self, configurations: config)
        let manager = TaskManager()
        manager.modelContext = ModelContext(container)
        return manager
    }

    @Test func clarificationAloneIsNotSuccess() throws {
        let manager = try makeManager()
        let clarify = PendingLLMCall(call: .requestClarification(ClarificationParams(reason: "몇 시에 할까요?")))

        let result = manager.executeDetailed(pendingCalls: [clarify])

        #expect(!result.allSucceeded)
        #expect(!result.hasAnySuccess)
        #expect(!manager.showUndoSnackbar)
        #expect(manager.undoStack.isEmpty)
        #expect(!manager.execute(llmCalls: [.requestClarification(ClarificationParams(reason: "몇 시에 할까요?"))]))
    }

    @Test func mixedClarificationAndMutationDoesNotPartiallySave() throws {
        let manager = try makeManager()
        let calls = [
            PendingLLMCall(call: .addSingleTask(AddSingleTaskParams(
                task_name: "약 먹기", time: nil, date: nil, category: "Routine", recurrence: nil, urgency: nil
            ))),
            PendingLLMCall(call: .requestClarification(ClarificationParams(reason: "회의는 몇 시인가요?"))),
        ]

        let result = manager.executeDetailed(pendingCalls: manager.preparePendingCalls(calls))

        #expect(!result.allSucceeded)
        #expect(!result.hasAnySuccess)
        #expect(result.items.allSatisfy { $0.issue == .invalidCommand })
        #expect(manager.taskCount() == 0)
        #expect(manager.undoStack.isEmpty)
    }

    @Test func noTimeEditClearsTimeOnUpdate() throws {
        let manager = try makeManager()
        let routine = AppTask(task: "운동", time: "07:00 AM", category: "Routine")
        manager.modelContext!.insert(routine)

        var pending = manager.preparePendingCalls([
            PendingLLMCall(call: .updateTask(UpdateTaskParams(
                target_task_name: "운동",
                new_task_name: nil,
                new_time: nil,
                new_date: nil,
                new_category: nil,
                new_recurrence: nil
            ))),
        ])[0]
        let baseline = try #require(pending.makeEditDraft())
        var edited = baseline
        edited.time = nil
        let didChange = pending.applyEdit(edited, from: baseline)
        #expect(didChange)
        pending.invalidatePreparedTargets()

        let result = manager.executeDetailed(
            pendingCalls: manager.preparePendingCalls([pending]),
            explicitlyConfirmed: true
        )

        #expect(result.allSucceeded)
        #expect(routine.time == nil)
        #expect(routine.category == "Routine")
        #expect(routine.date == nil)
    }
}
