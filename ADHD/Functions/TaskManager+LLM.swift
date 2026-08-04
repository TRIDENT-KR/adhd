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
                        refreshed.executionIssue = .staleTarget
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

    private func resolveTargetSnapshots(
        for call: LLMFunctionCall,
        in context: ModelContext
    ) throws -> [AppTaskSnapshot] {
        let all = try context.fetch(FetchDescriptor<AppTask>())
            .sorted { $0.id.uuidString < $1.id.uuidString }

        let targets: [AppTask]
        switch call {
        case .updateTask(let params):
            targets = bestMatch(name: params.target_task_name, in: all).map { [$0] } ?? []

        case .deleteSpecificTask(let params):
            targets = matchingTasks(
                name: params.target_task_name,
                category: params.target_category,
                dateString: params.target_date,
                in: all
            )

        case .clearAllTasks(let params):
            let isAllTime = params.target_date.lowercased() == "all"
            let targetDate = date(from: params.target_date)
            let finalCategory = params.target_category == nil && !isAllTime
                ? "Appointment"
                : params.target_category
            targets = all.filter { task in
                let dateMatches = isAllTime
                    || (targetDate.map { task.occursOn($0) } ?? false)
                let categoryMatches = finalCategory == nil
                    || finalCategory?.lowercased() == "all"
                    || task.category == finalCategory
                return dateMatches && categoryMatches
            }

        case .postponeAllTasks(let params):
            guard let fromDate = date(from: params.from_date) else { return [] }
            targets = all.filter { task in
                guard let taskDate = task.date else { return false }
                return task.recurrenceRule == nil
                    && Calendar.current.isDate(taskDate, inSameDayAs: fromDate)
            }

        case .markTaskComplete(let params):
            targets = bestMatch(name: params.target_task_name, in: all).map { [$0] } ?? []

        case .addSingleTask, .requestClarification, .handleOffTopicChat, .unknown:
            targets = []
        }

        return targets.map(AppTaskSnapshot.init)
    }

    private func bestMatch(name: String, in tasks: [AppTask]) -> AppTask? {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exact = tasks.first(where: { $0.task.lowercased() == query }) {
            return exact
        }
        guard query.count >= 2 else { return nil }
        return tasks.first(where: { $0.task.lowercased().contains(query) })
    }

    private func matchingTasks(
        name: String,
        category: String?,
        dateString: String?,
        in tasks: [AppTask]
    ) -> [AppTask] {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard query.count >= 2 else { return [] }
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
        return exact.isEmpty
            ? filtered.filter { $0.task.lowercased().contains(query) }
            : exact
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
            if let value = params.new_time { task.time = value }
            if let value = params.new_category { task.category = value }
            if let value = params.new_date, let parsed = date(from: value) {
                task.date = parsed
            }
            if let value = params.new_recurrence { task.recurrenceRule = value }
            if task.category == "Routine" { task.date = nil }
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

        case .requestClarification(let params):
            requestClarification(params: params)
            return AppliedLLMCall(
                affectedCount: 0,
                needsSave: false,
                undoAction: nil,
                notificationEffects: []
            )

        case .handleOffTopicChat(let params):
            handleOffTopicChat(params: params)
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

    // MARK: - Feedback-only Calls

    private func requestClarification(params: ClarificationParams) {
        undoSnackbarMessage = "🤔 \(params.reason)"
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            showUndoSnackbar = true
        }

        undoDismissWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                self.showUndoSnackbar = false
            }
        }
        undoDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    private func handleOffTopicChat(params: OffTopicChatParams) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .didReceiveOffTopicChat,
                object: nil,
                userInfo: ["message": params.message]
            )
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
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: string)
    }
}
