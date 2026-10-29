import Foundation
import SwiftData
import SwiftUI

struct LLMExecutionItemResult {
    let pendingCall: PendingLLMCall
    let didSucceed: Bool
    let affectedCount: Int
    let issue: LLMExecutionIssue?
}

struct LLMExecutionBatchResult {
    let items: [LLMExecutionItemResult]

    var allSucceeded: Bool {
        !items.isEmpty && items.allSatisfy(\.didSucceed)
    }

    var hasAnySuccess: Bool {
        items.contains(where: \.didSucceed)
    }

    var succeededIDs: Set<UUID> {
        Set(items.filter(\.didSucceed).map(\.pendingCall.id))
    }

    var remainingCalls: [PendingLLMCall] {
        items.filter { !$0.didSucceed }.map(\.pendingCall)
    }
}

// MARK: - TaskManager Function Calling Extension
extension TaskManager {

    /// 기존 호출부 호환용 API. 내부적으로 승인 대상 스냅샷을 먼저 만든 뒤 실행합니다.
    @discardableResult
    func execute(
        llmCalls: [LLMFunctionCall],
        explicitlyConfirmed: Bool = false
    ) -> Bool {
        let prepared = preparePendingCalls(
            llmCalls.map { PendingLLMCall(call: $0) }
        )
        return executeDetailed(
            pendingCalls: prepared,
            explicitlyConfirmed: explicitlyConfirmed
        ).allSucceeded
    }

    /// 기존 PendingLLMCall 호출부 호환용 API입니다. 새 UI는 executeDetailed 결과를 사용합니다.
    @discardableResult
    func execute(
        pendingCalls: [PendingLLMCall],
        explicitlyConfirmed: Bool = false
    ) -> Bool {
        let prepared = pendingCalls.map { pending in
            guard pending.call.requiresPreparedTargets,
                  pending.targetSnapshots == nil else { return pending }
            return preparePendingCalls([pending]).first ?? pending
        }
        return executeDetailed(
            pendingCalls: prepared,
            explicitlyConfirmed: explicitlyConfirmed
        ).allSucceeded
    }

    /// 확인 화면을 열 때 기존 태스크를 바꾸는 명령의 정확한 UUID와 전체 상태를 고정합니다.
    /// 승인 후 동일 이름 태스크가 추가되어도 이 목록 밖의 항목은 실행 대상이 되지 않습니다.
    func preparePendingCalls(_ pendingCalls: [PendingLLMCall]) -> [PendingLLMCall] {
        guard let context = modelContext else {
            return pendingCalls.map { pending in
                var failed = pending
                failed.executionIssue = .storeUnavailable
                return failed
            }
        }

        return pendingCalls.map { pending in
            var prepared = pending
            prepared.targetCandidates = []
            guard pending.call.requiresPreparedTargets else {
                prepared.targetSnapshots = []
                prepared.executionIssue = nil
                return prepared
            }

            do {
                prepared.targetSnapshots = try resolveTargetSnapshots(
                    for: pending.call,
                    in: context
                )
                prepared.executionIssue = nil
                prepared.requiresReconfirmation = false
            } catch TargetResolutionError.ambiguous(let candidates) {
                prepared.targetSnapshots = []
                prepared.targetCandidates = candidates
                prepared.executionIssue = .ambiguousTarget
                prepared.requiresReconfirmation = false
            } catch {
                prepared.targetSnapshots = nil
                prepared.executionIssue = .persistenceFailed
            }
            return prepared
        }
    }

    /// 한 승인 묶음을 항목별로 저장합니다.
    /// 일반 항목 실패는 다음 항목을 계속 처리하고, 저장소 오류만 이후 항목을 중단합니다.
    func executeDetailed(
        pendingCalls: [PendingLLMCall],
        explicitlyConfirmed: Bool = false
    ) -> LLMExecutionBatchResult {
        guard !pendingCalls.isEmpty else {
            return LLMExecutionBatchResult(items: [])
        }

        guard let context = modelContext else {
            return failureResult(for: pendingCalls, issue: .storeUnavailable)
        }

        let calls = pendingCalls.map(\.call)
        guard calls.count <= 50,
              calls.count == 1 || !calls.contains(where: {
                  if case .requestClarification = $0 { return true }
                  return $0.isOffTopic
              }) else { return failureResult(for: pendingCalls, issue: .invalidCommand) }
        guard explicitlyConfirmed
                || !LLMConfirmationPolicy.requiresExplicitConfirmation(for: calls) else {
            print("ai_command_execution_blocked reason=confirmation_required count=\(calls.count)")
            return failureResult(for: pendingCalls, issue: .confirmationRequired)
        }

        var results: [LLMExecutionItemResult] = []
        var undoActions: [UndoableAction.ActionType] = []
        var didPersistMutation = false
        var stoppedForStoreFailure = false

        for originalPending in pendingCalls {
            // 되묻기·잡담은 저장할 내용이 없으므로 실행 결과(성공·실패)에 넣지 않습니다.
            // 화면은 이 응답을 따로 안내하고 초안을 그대로 둡니다.
            if originalPending.call.isFeedbackOnly { continue }

            if stoppedForStoreFailure {
                results.append(
                    failedItem(originalPending, issue: .notExecutedAfterStoreFailure)
                )
                continue
            }

            guard originalPending.call.isExecutionPayloadValid else {
                let issue: LLMExecutionIssue = originalPending.call.isUnknown
                    ? .unsupportedCommand
                    : .invalidCommand
                results.append(failedItem(originalPending, issue: issue))
                continue
            }

            if originalPending.call.requiresPreparedTargets {
                guard originalPending.executionIssue != .ambiguousTarget else {
                    results.append(failedItem(originalPending, issue: .ambiguousTarget))
                    continue
                }
                guard let expected = originalPending.targetSnapshots else {
                    results.append(failedItem(originalPending, issue: .previewRequired))
                    continue
                }
                guard !expected.isEmpty else {
                    results.append(failedItem(originalPending, issue: .noMatchingTarget))
                    continue
                }

                do {
                    let isUnchanged = try expected.allSatisfy { snapshot in
                        guard let current = try fetchTaskThrowing(
                            id: snapshot.id,
                            in: context
                        ) else { return false }
                        return snapshot.matches(current)
                    }

                    guard isUnchanged else {
                        var refreshed = preparePendingCalls([originalPending]).first
                            ?? originalPending
                        // 다시 모호해진 대상은 후보 선택 UI를 유지합니다.
                        if refreshed.executionIssue != .ambiguousTarget {
                            refreshed.executionIssue = .staleTarget
                        }
                        refreshed.requiresReconfirmation = true
                        results.append(
                            LLMExecutionItemResult(
                                pendingCall: refreshed,
                                didSucceed: false,
                                affectedCount: 0,
                                issue: .staleTarget
                            )
                        )
                        continue
                    }
                } catch {
                    context.rollback()
                    stoppedForStoreFailure = true
                    results.append(failedItem(originalPending, issue: .persistenceFailed))
                    continue
                }
            }

            do {
                let applied = try apply(originalPending, in: context)
                if applied.needsSave {
                    try context.save()
                    didPersistMutation = true
                }
                applyNotificationEffects(applied.notificationEffects)
                if let undoAction = applied.undoAction {
                    undoActions.append(undoAction)
                }
                var succeeded = originalPending
                succeeded.executionIssue = nil
                succeeded.requiresReconfirmation = false
                results.append(
                    LLMExecutionItemResult(
                        pendingCall: succeeded,
                        didSucceed: true,
                        affectedCount: applied.affectedCount,
                        issue: nil
                    )
                )
            } catch {
                context.rollback()
                stoppedForStoreFailure = true
                results.append(failedItem(originalPending, issue: .persistenceFailed))
            }
        }

        if didPersistMutation {
            writeWidgetSnapshot()
        }
        if !undoActions.isEmpty {
            let changedItemCount = results.filter {
                $0.didSucceed && $0.affectedCount > 0
            }.count
            setUndoAction(
                .grouped(undoActions),
                message: L.voice.undoBatch(changedItemCount)
            )
        }

        return LLMExecutionBatchResult(items: results)
    }

    // MARK: - Target Preparation

    private enum TargetResolutionError: Error {
        case ambiguous([AppTaskSnapshot])
    }

    private func resolveTargetSnapshots(
        for call: LLMFunctionCall,
        in context: ModelContext
    ) throws -> [AppTaskSnapshot] {
        let all = try context.fetch(FetchDescriptor<AppTask>())
            .sorted { $0.id.uuidString < $1.id.uuidString }

        let targets: [AppTask]
        switch call {
        case .updateTask(let params):
            targets = try uniqueMatch(name: params.target_task_name, in: all)

        case .deleteSpecificTask(let params):
            targets = matchingTasks(
                name: params.target_task_name,
                category: params.target_category,
                dateString: params.target_date,
                in: all
            )

        case .clearAllTasks(let params):
            targets = Self.clearTargets(for: params, in: all)

        case .postponeAllTasks(let params):
            guard let fromDate = date(from: params.from_date) else { return [] }
            targets = all.filter { task in
                guard let taskDate = task.date else { return false }
                return task.recurrenceRule == nil
                    && Calendar.current.isDate(taskDate, inSameDayAs: fromDate)
            }

        case .markTaskComplete(let params):
            targets = try uniqueMatch(name: params.target_task_name, in: all)

        case .addSingleTask, .requestClarification, .handleOffTopicChat, .unknown:
            targets = []
        }

        return targets.map(AppTaskSnapshot.init)
    }

    private func uniqueMatch(name: String, in tasks: [AppTask]) throws -> [AppTask] {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let exact = tasks.filter { $0.task.lowercased() == query }
        let matches = !exact.isEmpty ? exact : (query.count >= 2
            ? tasks.filter { $0.task.lowercased().contains(query) } : [])
        guard matches.count <= 1 else {
            throw TargetResolutionError.ambiguous(matches.map(AppTaskSnapshot.init))
        }
        return matches
    }

    /// "오늘 일정 다 지워줘"처럼 날짜를 정한 일괄 삭제는 그날 하루짜리 일정만 대상으로 합니다.
    /// 반복 일정은 기록 하나가 시리즈 전체이고, 날짜 없는 루틴은 매일 반복분 전체라서
    /// 지우면 그날 밖의 일정까지 사라지므로 제외합니다(일괄 연기와 같은 기준).
    /// "all"(전체 삭제)은 사용자가 모두 지우겠다고 말한 경우라 반복·루틴도 포함합니다.
    static func clearTargets(
        for params: ClearTasksParams,
        in tasks: [AppTask],
        calendar: Calendar = .current
    ) -> [AppTask] {
        let isAllTime = params.target_date.lowercased() == "all"
        let targetDate = StoredTaskFormat.date.date(from: params.target_date)
        let finalCategory = params.target_category == nil && !isAllTime
            ? "Appointment"
            : params.target_category

        return tasks.filter { task in
            let categoryMatches = finalCategory == nil
                || finalCategory?.lowercased() == "all"
                || task.category == finalCategory
            guard categoryMatches else { return false }
            if isAllTime { return true }

            guard let targetDate,
                  let taskDate = task.date,
                  task.recurrenceRule == nil else { return false }
            return calendar.isDate(taskDate, inSameDayAs: targetDate)
        }
    }

    /// 같은 이름 후보 중 사용자가 말한 대상일 가능성이 가장 높은 하나를 고릅니다.
    /// 정확히 같은 이름 → 부분 일치 순으로 찾고, 같은 단계 안에서는
    /// 미완료 → 오늘 이후 가장 가까운 일정 → 지난 일정 중 가장 최근 → 이른 시간 → id 순으로 정합니다.
    static func bestMatch(
        name: String,
        in tasks: [AppTask],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> AppTask? {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let exact = tasks.filter { $0.task.lowercased() == query }
        if !exact.isEmpty {
            return rankedMatches(exact, now: now, calendar: calendar).first
        }
        guard query.count >= 2 else { return nil }
        let partial = tasks.filter { $0.task.lowercased().contains(query) }
        return rankedMatches(partial, now: now, calendar: calendar).first
    }

    private struct MatchRank: Comparable {
        let completed: Int
        /// 0 = 오늘 이후 발생 있음, 1 = 지난 일정만 있음
        let timing: Int
        /// timing 0이면 다음 발생까지 일수, 1이면 마지막 날짜로부터 지난 일수
        let distanceDays: Int
        let sortableTime: String
        let id: String

        static func < (lhs: MatchRank, rhs: MatchRank) -> Bool {
            (lhs.completed, lhs.timing, lhs.distanceDays, lhs.sortableTime, lhs.id)
                < (rhs.completed, rhs.timing, rhs.distanceDays, rhs.sortableTime, rhs.id)
        }
    }

    private static func rankedMatches(
        _ tasks: [AppTask],
        now: Date,
        calendar: Calendar
    ) -> [AppTask] {
        let today = calendar.startOfDay(for: now)
        return tasks
            .map { task -> (AppTask, MatchRank) in
                let upcoming = daysUntilNextOccurrence(of: task, from: today, calendar: calendar)
                let pastDays = task.date.map {
                    calendar.dateComponents([.day], from: calendar.startOfDay(for: $0), to: today).day ?? Int.max
                } ?? Int.max
                return (task, MatchRank(
                    completed: task.isCompleted ? 1 : 0,
                    timing: upcoming == nil ? 1 : 0,
                    distanceDays: upcoming ?? pastDays,
                    sortableTime: task.sortableTime,
                    id: task.id.uuidString
                ))
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// 오늘부터 다음 발생일까지의 일수입니다. 오늘 이후 발생이 없으면 nil입니다.
    private static func daysUntilNextOccurrence(
        of task: AppTask,
        from today: Date,
        calendar: Calendar
    ) -> Int? {
        guard let date = task.date else {
            // 날짜 없는 루틴은 매일 반복이므로 오늘 발생합니다.
            return task.category == "Appointment" ? nil : 0
        }
        guard task.category == "Appointment", task.recurrenceRule != nil else {
            let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day ?? -1
            return days >= 0 ? days : nil
        }
        // 반복 규칙은 모두 1년 안에 다음 발생일이 있으므로 윤년 여유를 두고 찾습니다.
        for offset in 0...370 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            if task.occursOn(day, calendar: calendar) { return offset }
        }
        return nil
    }

    private func matchingTasks(
        name: String,
        category: String?,
        dateString: String?,
        in tasks: [AppTask]
    ) -> [AppTask] {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        let parsedDate = date(from: dateString)

        let filtered = tasks.filter { item in
            if let category,
               category.lowercased() != "all",
               item.category != category {
                return false
            }
            if let parsedDate {
                guard let itemDate = item.date,
                      Calendar.current.isDate(itemDate, inSameDayAs: parsedDate) else {
                    return false
                }
            }
            return true
        }

        let exact = filtered.filter { $0.task.lowercased() == query }
        if !exact.isEmpty { return exact }
        // 한 글자 이름은 부분 일치를 쓰지 않습니다('약'이 '예약'·'약속'까지 지우지 않게).
        guard query.count >= 2 else { return [] }
        return filtered.filter { $0.task.lowercased().contains(query) }
    }

    // MARK: - Per-item Persistence

    private struct AppliedLLMCall {
        let affectedCount: Int
        let needsSave: Bool
        let undoAction: UndoableAction.ActionType?
        let notificationEffects: [NotificationEffect]
    }

    private enum NotificationEffect {
        case cancel(AppTaskSnapshot)
        case schedule(AppTaskSnapshot)
        case completed(AppTaskSnapshot)
    }

    private enum ApplyError: Error {
        case targetMissing
        case invalidDate
    }

    private func apply(
        _ pending: PendingLLMCall,
        in context: ModelContext
    ) throws -> AppliedLLMCall {
        switch pending.call {
        case .addSingleTask(let params):
            let task = AppTask(
                task: params.task_name,
                time: normalizedTime(params.time),
                date: date(from: params.date)
                    ?? (params.category == "Routine" ? nil : Date()),
                category: params.category,
                recurrenceRule: params.recurrence,
                urgency: pending.urgency
            )
            task.normalizeSchedule()
            placeNewTask(task, in: context)
            context.insert(task)
            return AppliedLLMCall(
                affectedCount: 1,
                needsSave: true,
                undoAction: .added([task.id]),
                notificationEffects: [.schedule(AppTaskSnapshot(task))]
            )

        case .updateTask(let params):
            guard let expected = pending.targetSnapshots?.first,
                  let task = try fetchTaskThrowing(id: expected.id, in: context) else {
                throw ApplyError.targetMissing
            }
            let previous = AppTaskSnapshot(task)
            if let value = params.new_task_name { task.task = value }
            // 빈 문자열은 확인 카드에서 "시간 없음"으로 바꾼 경우입니다.
            if let value = params.new_time { task.time = normalizedTime(value) }
            if let value = params.new_category { task.category = value }
            if let value = params.new_date, let parsed = date(from: value) {
                task.date = parsed
            }
            if let value = params.new_recurrence { task.recurrenceRule = value }
            if task.category == "Routine" { task.date = nil }
            // 루틴→일정으로 바꾸면 날짜가 없어 어디에도 안 보이면서 매일 울리던 문제를 막습니다.
            task.normalizeSchedule()
            let changed = !previous.matches(task)
            return AppliedLLMCall(
                affectedCount: changed ? 1 : 0,
                needsSave: changed,
                undoAction: changed ? .updated(previous: previous) : nil,
                notificationEffects: changed
                    ? [.cancel(previous), .schedule(AppTaskSnapshot(task))]
                    : []
            )

        case .deleteSpecificTask, .clearAllTasks:
            let expected = pending.targetSnapshots ?? []
            let tasks = try fetchTargets(expected, in: context)
            for task in tasks { context.delete(task) }
            return AppliedLLMCall(
                affectedCount: tasks.count,
                needsSave: !tasks.isEmpty,
                undoAction: tasks.isEmpty ? nil : .deleted(expected),
                notificationEffects: expected.map(NotificationEffect.cancel)
            )

        case .postponeAllTasks(let params):
            guard let toDate = date(from: params.to_date) else {
                throw ApplyError.invalidDate
            }
            let expected = pending.targetSnapshots ?? []
            let tasks = try fetchTargets(expected, in: context)
            let previous = tasks.map(AppTaskSnapshot.init)
            for task in tasks { task.date = toDate }
            let current = tasks.map(AppTaskSnapshot.init)
            return AppliedLLMCall(
                affectedCount: tasks.count,
                needsSave: !tasks.isEmpty,
                undoAction: tasks.isEmpty
                    ? nil
                    : .grouped(previous.map { .updated(previous: $0) }),
                notificationEffects: previous.map(NotificationEffect.cancel)
                    + current.map(NotificationEffect.schedule)
            )

        case .markTaskComplete:
            guard let expected = pending.targetSnapshots?.first,
                  let task = try fetchTaskThrowing(id: expected.id, in: context) else {
                throw ApplyError.targetMissing
            }
            let wasCompleted = task.isCompleted
            task.isCompleted = true
            return AppliedLLMCall(
                affectedCount: wasCompleted ? 0 : 1,
                needsSave: !wasCompleted,
                undoAction: wasCompleted
                    ? nil
                    : .toggled(taskID: task.id, previousState: false),
                notificationEffects: wasCompleted
                    ? []
                    : [.completed(AppTaskSnapshot(task))]
            )

        case .requestClarification, .handleOffTopicChat:
            // executeDetailed에서 먼저 걸러지므로 여기까지 오지 않습니다.
            // 되돌리기 스낵바 등 다른 화면 상태를 건드리지 않도록 아무것도 하지 않습니다.
            return AppliedLLMCall(
                affectedCount: 0,
                needsSave: false,
                undoAction: nil,
                notificationEffects: []
            )

        case .unknown:
            throw ApplyError.targetMissing
        }
    }

    private func fetchTargets(
        _ snapshots: [AppTaskSnapshot],
        in context: ModelContext
    ) throws -> [AppTask] {
        var tasks: [AppTask] = []
        for snapshot in snapshots {
            guard let task = try fetchTaskThrowing(id: snapshot.id, in: context) else {
                throw ApplyError.targetMissing
            }
            tasks.append(task)
        }
        return tasks
    }

    private func fetchTaskThrowing(
        id: UUID,
        in context: ModelContext
    ) throws -> AppTask? {
        let descriptor = FetchDescriptor<AppTask>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }

    private func applyNotificationEffects(_ effects: [NotificationEffect]) {
        for effect in effects {
            switch effect {
            case .cancel(let snapshot):
                NotificationManager.shared.cancelNotification(for: snapshot.makeTask())
            case .schedule(let snapshot):
                NotificationManager.shared.scheduleNotification(for: snapshot.makeTask())
            case .completed(let snapshot):
                clearNotificationsAfterCompletion(of: snapshot.makeTask())
            }
        }
    }

    // MARK: - Result Helpers

    private func failureResult(
        for pendingCalls: [PendingLLMCall],
        issue: LLMExecutionIssue
    ) -> LLMExecutionBatchResult {
        LLMExecutionBatchResult(
            items: pendingCalls.map { failedItem($0, issue: issue) }
        )
    }

    private func failedItem(
        _ pending: PendingLLMCall,
        issue: LLMExecutionIssue
    ) -> LLMExecutionItemResult {
        var failed = pending
        failed.executionIssue = issue
        return LLMExecutionItemResult(
            pendingCall: failed,
            didSucceed: false,
            affectedCount: 0,
            issue: issue
        )
    }

    private func normalizedTime(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func date(from string: String?) -> Date? {
        guard let string, string.lowercased() != "all" else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.isLenient = false
        guard let date = formatter.date(from: string), formatter.string(from: date) == string else { return nil }
        return date
    }
}
