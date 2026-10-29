import Foundation
import SwiftUI
import Combine
import SwiftData
import WidgetKit
import UserNotifications

// Removed ParsedTask

// MARK: - Task Snapshot
/// 승인 시점의 정확한 대상과 Undo 복원에 공통으로 사용하는 전체 스냅샷입니다.
/// 이름 재검색 대신 UUID를 사용하여, 승인 후 같은 이름의 태스크가 추가되어도 범위가 넓어지지 않습니다.
struct AppTaskSnapshot {
    let id: UUID
    let task: String
    let time: String?
    let date: Date?
    let category: String
    let isCompleted: Bool
    let recurrenceRule: String?
    let urgency: Urgency
    let sortOrder: Int
    let weeklyCompletions: [Bool]
    let skippedDayKeys: [String]

    init(_ task: AppTask) {
        id = task.id
        self.task = task.task
        time = task.time
        date = task.date
        category = task.category
        isCompleted = task.isCompleted
        recurrenceRule = task.recurrenceRule
        urgency = task.urgency
        sortOrder = task.sortOrder
        weeklyCompletions = task.weeklyCompletions
        skippedDayKeys = task.skippedDayKeys
    }

    func matches(_ candidate: AppTask) -> Bool {
        candidate.id == id
            && candidate.task == task
            && candidate.time == time
            && candidate.date == date
            && candidate.category == category
            && candidate.isCompleted == isCompleted
            && candidate.recurrenceRule == recurrenceRule
            && candidate.urgency == urgency
            && candidate.sortOrder == sortOrder
            && candidate.weeklyCompletions == weeklyCompletions
            && candidate.skippedDayKeys == skippedDayKeys
    }

    func makeTask() -> AppTask {
        let restored = AppTask(
            id: id,
            task: task,
            time: time,
            date: date,
            category: category,
            isCompleted: isCompleted,
            recurrenceRule: recurrenceRule,
            sortOrder: sortOrder,
            urgency: urgency
        )
        restored.weeklyCompletions = weeklyCompletions
        restored.skippedDayKeys = skippedDayKeys
        return restored
    }

    func restore(_ target: AppTask) {
        target.task = task
        target.time = time
        target.date = date
        target.category = category
        target.isCompleted = isCompleted
        target.recurrenceRule = recurrenceRule
        target.urgency = urgency
        target.sortOrder = sortOrder
        target.weeklyCompletions = weeklyCompletions
        target.skippedDayKeys = skippedDayKeys
    }
}

// MARK: - Undo Action
/// 되돌리기를 위한 최근 액션 저장
struct UndoableAction {
    indirect enum ActionType {
        case added([UUID])
        case deleted([AppTaskSnapshot])
        case updated(previous: AppTaskSnapshot)
        case toggled(taskID: UUID, previousState: Bool)
        /// 한 번의 사용자 승인으로 성공한 변경은 한 번의 Undo로 되돌립니다.
        case grouped([ActionType])
    }
    let type: ActionType
    let message: String
    let timestamp: Date = Date()
}

// MARK: - TaskManager
/// SwiftData ModelContext를 주입받아 AppTask의 CRUD를 담당합니다.
@MainActor
class TaskManager: ObservableObject {

    // 외부에서 ModelContext를 주입하기 위한 저장소
    var modelContext: ModelContext?

    /// 데이터 로딩 완료 여부 (스플래시 → 메인 화면 전환 트리거)
    @Published var isReady = false

    // Undo 지원 (스택 기반 — 최대 10단계)
    var undoStack: [UndoableAction] = []
    static let maxUndoDepth = 10
    @Published var showUndoSnackbar = false
    @Published var undoSnackbarMessage = ""
    var undoDismissWorkItem: DispatchWorkItem?

    /// App.swift에서 modelContext를 주입합니다.
    func configure(context: ModelContext) {
        self.modelContext = context
        // 메인 화면을 즉시 표시한 뒤 무거운 초기화를 실행 (첫 실행 렉 방지)
        isReady = true
        Task { @MainActor in
            // 콜드 런치에는 scenePhase 변화가 오지 않으므로, 앱이 꺼진 동안
            // 알림·알람·위젯에서 누른 완료를 여기서 날짜 초기화 앞뒤로 반영합니다.
            processPendingAlarmCompletions()
            syncWidgetToggles()
            checkAndResetDailyTasks()
            syncWidgetToggles()
            writeWidgetSnapshot()
        }
    }

    // MARK: - Daily / Weekly Reset Logic
    private let lastResetKey = "lastResetDate"

    /// ISO 8601 기준 캘린더 (주 시작: 월요일). 타임존은 기기 로컬 자동 적용.
    private var isoCalendar: Calendar {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = .current
        return cal
    }

    /// 0=월, 1=화, … 6=일
    private func isoWeekdayIndex(of date: Date) -> Int {
        WeekdayIndex.mondayBased(date, calendar: isoCalendar)
    }

    /// 두 날짜가 서로 다른 ISO 주(週)에 속하는지 확인
    private func isDifferentISOWeek(_ a: Date, _ b: Date) -> Bool {
        let cal = isoCalendar
        let weekA = cal.component(.weekOfYear,       from: a)
        let weekB = cal.component(.weekOfYear,       from: b)
        let yearA = cal.component(.yearForWeekOfYear, from: a)
        let yearB = cal.component(.yearForWeekOfYear, from: b)
        return weekA != weekB || yearA != yearB
    }

    /// 날짜가 바뀌었는지 확인하고 루틴/반복 일정을 초기화합니다.
    /// - 매일: 리셋 전 어제 완료 여부를 weeklyCompletions에 기록
    /// - 주 경계(일→월): weeklyCompletions 전체 초기화
    /// now/defaults 파라미터는 단위 테스트 주입용 (기존 무인자 호출은 그대로 유효)
    /// 저장소가 계정마다 따로이므로 기준일도 계정별로 둡니다. 게스트는 기존 전역 키를 씁니다.
    /// 계정 키가 아직 없으면(업데이트 직후) 기존 전역 값을 한 번 이어받습니다.
    private func lastResetRecord(defaults: UserDefaults) -> (key: String, date: Date?) {
        let resetKey = AccountPreferences.scopedKey(AccountPreferences.lastResetDateBase, defaults: defaults)
            ?? lastResetKey
        let date = (defaults.object(forKey: resetKey) ?? defaults.object(forKey: lastResetKey)) as? Date
        return (resetKey, date)
    }

    /// 오늘 일일 초기화가 아직이면(저장된 완료 상태가 이전 날짜 기준이면) true입니다.
    func isDailyResetPending(now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        guard let lastReset = lastResetRecord(defaults: defaults).date else { return true }
        return !Calendar.current.isDate(lastReset, inSameDayAs: now)
    }

    func checkAndResetDailyTasks(now: Date = Date(), defaults: UserDefaults = .standard) {
        guard let context = modelContext else { return }
        let (resetKey, lastReset) = lastResetRecord(defaults: defaults)

        guard lastReset == nil || !Calendar.current.isDate(lastReset!, inSameDayAs: now) else { return }

        print("🌅 새로운 날 발견: 일일 태스크 초기화 중...")
        do {
            let allTasks = try context.fetch(FetchDescriptor<AppTask>())
            let routineTasks = allTasks.filter { $0.category == "Routine" || $0.isRecurring }

            // 1) 어제(lastReset) 요일에 완료 여부 기록
            if let lastReset {
                let dayIndex = isoWeekdayIndex(of: lastReset)
                for task in routineTasks {
                    task.weeklyCompletions[dayIndex] = task.isCompleted
                }
                print("📅 weeklyCompletions[\(dayIndex)] 업데이트 완료 (\(routineTasks.count)개)")
            }

            // 2) 주 경계 넘으면 weekly 초기화
            if let lastReset, isDifferentISOWeek(lastReset, now) {
                for task in routineTasks {
                    task.weeklyCompletions = Array(repeating: false, count: 7)
                }
                print("📆 새로운 주 감지: weeklyCompletions 초기화 완료")
            }

            // 3) isCompleted 리셋
            var resetTasks: [AppTask] = []
            for task in routineTasks where task.isCompleted {
                task.isCompleted = false
                resetTasks.append(task)
            }
            let resetCount = resetTasks.count

            defaults.set(now, forKey: resetKey)
            safeSave()

            // 4) 어제 완료하면서 '오늘만 건너뛰기'로 바꿔 둔 알림을 원래 반복 예약으로 되돌림
            for task in resetTasks {
                NotificationManager.shared.scheduleNotification(for: task)
            }
            print("✅ \(resetCount)개의 태스크 초기화 완료.")
        } catch {
            print("daily_reset_failed")
        }
    }

    // Process logic moved to TaskManager+LLM.swift (execute method)
    
    // MARK: - Core Actions
    /// 특정 ID의 태스크를 '완료' 상태로 직접 설정 (알람 확인/완료 액션 시 사용)
    func completeTask(id: UUID) {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<AppTask>(predicate: #Predicate { $0.id == id })
        do {
            if let task = try context.fetch(descriptor).first {
                if !task.isCompleted {
                    task.isCompleted = true
                    safeSave()
                    print("alarm_task_completed")
                    // 위젯 및 알림 갱신
                    writeWidgetSnapshot()
                    clearNotificationsAfterCompletion(of: task)
                }
            }
        } catch {
            print("task_completion_failed")
        }
    }

    /// 완료 시 알림 정리:
    /// 반복 태스크(루틴/반복 일정)는 파생(팔로업/스누즈)을 지우고, 오늘 아직 울리지 않은 회차만 뺀
    /// 예약으로 바꿉니다(다음 회차는 유지). 다음 날 일일 초기화가 원래 반복 예약으로 되돌립니다.
    /// 일회성은 본체+파생+AlarmKit 전부 취소.
    func clearNotificationsAfterCompletion(of task: AppTask) {
        let isRepeating = task.isRecurring || task.date == nil
        if isRepeating {
            NotificationManager.shared.cancelFollowUps(taskIdString: task.id.uuidString)
            NotificationManager.shared.scheduleNotification(for: task)
        } else {
            NotificationManager.shared.cancelNotification(for: task)
        }
    }

    /// 알림 액션/AlarmKit Stop이 App Group 큐에 적재한 완료 요청을 일괄 처리합니다.
    /// (scenePhase active 및 .alarmTaskCompleted 수신 시 호출)
    /// 포그라운드에 도착한 알림이 이미 완료한 태스크의 것인지 확인합니다.
    func isTaskCompleted(id: UUID) -> Bool {
        guard let context = modelContext else { return false }
        let descriptor = FetchDescriptor<AppTask>(predicate: #Predicate { $0.id == id })
        return (try? context.fetch(descriptor).first?.isCompleted) ?? false
    }

    func processPendingAlarmCompletions() {
        let queue = AlarmCompletionRelay.drain()
        guard !queue.isEmpty else { return }

        for idString in queue {
            guard let uuid = UUID(uuidString: idString) else { continue }
            completeTask(id: uuid)
        }
        print("✅ 알람 완료 큐 \(queue.count)건 처리")
    }

    /// 모든 미완료 strong 태스크를 재스케줄합니다.
    /// 백엔드 이관 트리거(구독 상태 변경 / AlarmKit 권한 획득)와
    /// biweekly·monthly·yearly 고정 알람의 재무장(포그라운드 진입)에 공용으로 사용.
    func rescheduleAllStrongTasks() {
        guard let context = modelContext else { return }
        do {
            let all = try context.fetch(FetchDescriptor<AppTask>())
            for task in all where task.urgency == .strong && (!task.isCompleted || task.hasRepeatingSchedule) {
                NotificationManager.shared.scheduleNotification(for: task)
            }
        } catch {
            print("strong_task_reschedule_failed")
        }
    }

    /// 한 회차씩 거는 반복(격주·매월·매년), 건너뛴 회차가 남은 반복, 시작 전인 매주 반복은
    /// 강도와 무관하게 포그라운드마다 다음 회차를 다시 계산합니다.
    func rescheduleTasksNeedingRearm() {
        guard let context = modelContext else { return }
        do {
            let all = try context.fetch(FetchDescriptor<AppTask>())
            // 오래된 건너뛰기 기록은 지워, 다 지나간 기록 때문에 매번 다시 계산하지 않게 합니다.
            var pruned = false
            if let cutoff = Calendar.current.date(byAdding: .day, value: -60, to: Date()) {
                let cutoffKey = AppTask.dayKey(cutoff)
                for task in all where task.skippedDayKeys.contains(where: { $0 < cutoffKey }) {
                    task.pruneSkippedDayKeys(before: cutoff)
                    pruned = true
                }
            }
            if pruned { safeSave() }
            for task in all where NotificationManager.needsForegroundRearm(task) {
                NotificationManager.shared.scheduleNotification(for: task)
            }
        } catch {
            print("recurring_notification_reschedule_failed")
        }
    }

    /// iOS는 대기 알림을 가장 가까운 64건만 남기고 나머지는 조용히 버립니다.
    /// 포그라운드마다 예약이 사라진 할 일을 다시 걸어, 앞선 알림이 울려 자리가 나면 먼 일정도 채워지게 합니다.
    func refillDroppedNotifications() {
        Task { @MainActor in
            let scheduledIds = await NotificationManager.shared.pendingTaskIds()
            guard let context = modelContext,
                  let tasks = try? context.fetch(FetchDescriptor<AppTask>()) else { return }
            // AlarmKit으로 울리는 strong 태스크는 UN 대기 목록에 없으므로 제외합니다(별도 재무장).
            let alarmKitManaged = WidgetDataStore.isPremium && SystemAlarmScheduler.shared.isAuthorized
            var refilled = 0
            for task in tasks where !scheduledIds.contains(task.id) {
                guard task.time?.isEmpty == false,
                      !task.isCompleted || task.hasRepeatingSchedule,
                      !(alarmKitManaged && task.urgency == .strong) else { continue }
                NotificationManager.shared.scheduleNotification(for: task)
                refilled += 1
            }
            if refilled > 0 { print("notification_refill count=\(refilled)") }
        }
    }

    /// 앱 언어를 바꾸면 이미 예약된 알림 문구와 버튼 이름, 위젯 문구를 새 언어로 다시 만듭니다.
    func refreshForLanguageChange() {
        NotificationManager.shared.refreshCategoriesForLanguageChange()
        if let context = modelContext,
           let tasks = try? context.fetch(FetchDescriptor<AppTask>()) {
            for task in tasks where !task.isCompleted || task.hasRepeatingSchedule {
                NotificationManager.shared.scheduleNotification(for: task)
            }
        }
        writeWidgetSnapshot()
    }

    /// 현재 계정의 알림 설정이 바뀌면 기존 예약을 모두 폐기하고 저장소를 원천으로 재구성합니다.
    func reconcileNotificationsWithPreferences() {
        guard let context = modelContext else { return }
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()

        do {
            let tasks = try context.fetch(FetchDescriptor<AppTask>())
            for task in tasks {
                NotificationManager.shared.cancelNotification(for: task)
                // 반복 태스크는 오늘 완료했어도 다음 회차 알림을 다시 겁니다(오늘 남은 회차는 예약 단계에서 뺌).
                if !task.isCompleted || task.hasRepeatingSchedule {
                    NotificationManager.shared.scheduleNotification(for: task)
                }
            }
        } catch {
            print("notification_preference_reconcile_failed")
        }
    }

    /// 삭제된 태스크의 고아 알림/알람을 회수합니다.
    /// 등록(비동기)-삭제 경합이나 과거 버전이 남긴 잔재가 있어도
    /// 포그라운드 진입 시 실존 태스크 기준으로 자가치유됩니다.
    func cleanupOrphanedNotifications() {
        guard let context = modelContext else { return }
        do {
            let validIds = Set(try context.fetch(FetchDescriptor<AppTask>()).map(\.id))
            NotificationManager.shared.removeOrphanedNotifications(validIds: validIds)
            SystemAlarmScheduler.shared.cancelOrphans(keeping: validIds)
        } catch {
            print("notification_orphan_cleanup_failed")
        }
    }

    /// Pro + AlarmKit 허용 상태에서만 재무장 (매 포그라운드 호출용 가드)
    func rescheduleStrongTasksIfNeeded() {
        rescheduleTasksNeedingRearm()
        guard WidgetDataStore.isPremium,
              SystemAlarmScheduler.shared.isAuthorized else { return }
        rescheduleAllStrongTasks()
    }

    // MARK: - Toggle Completion
    func toggleCompletion(of task: AppTask) {
        let previousState = task.isCompleted
        task.isCompleted.toggle()
        if task.isCompleted {
            clearNotificationsAfterCompletion(of: task)
        } else {
            // 완료 해제 → 알림 재무장
            NotificationManager.shared.scheduleNotification(for: task)
        }
        safeSave()
        setUndoAction(
            .toggled(taskID: task.id, previousState: previousState),
            message: task.isCompleted ? L.voice.undoCompleted : L.voice.undoUncompleted
        )
    }

    // MARK: - Update Task
    func update(task: AppTask) {
        safeSave()
        NotificationManager.shared.scheduleNotification(for: task)
    }

    // MARK: - Skip One Occurrence
    /// 반복 일정·루틴의 한 회차만 건너뜁니다. 시리즈와 다른 날 알림은 그대로 두고, 되돌릴 수 있습니다.
    func skipOccurrence(of task: AppTask, on date: Date) {
        guard task.hasRepeatingSchedule, !task.isSkipped(on: date) else { return }
        let previous = AppTaskSnapshot(task)
        task.skippedDayKeys.append(AppTask.dayKey(date))
        if let monthAgo = Calendar.current.date(byAdding: .day, value: -60, to: Date()) {
            task.pruneSkippedDayKeys(before: monthAgo)
        }
        safeSave()
        NotificationManager.shared.scheduleNotification(for: task)
        writeWidgetSnapshot()
        setUndoAction(.updated(previous: previous), message: L.voice.undoSkippedOccurrence(task.task))
    }

    // MARK: - Delete (by reference)
    func delete(task: AppTask) {
        // 삭제 버튼을 빠르게 두 번 눌러도 이미 지운 항목을 다시 지우거나 되돌리기를 두 번 쌓지 않습니다.
        guard let context = modelContext, task.modelContext != nil, !task.isDeleted else { return }
        let snapshot = AppTaskSnapshot(task)
        NotificationManager.shared.cancelNotification(for: task)
        context.delete(task)
        safeSave()
        setUndoAction(.deleted([snapshot]), message: L.voice.undoDeletedSingle(snapshot.task))
    }

    // MARK: - Undo (스택 기반)
    func undo() {
        guard let action = undoStack.popLast() else { return }

        guard let context = modelContext else { return }
        applyUndo(action.type, in: context)
        safeSave()

        // 스택에 남은 항목이 있으면 이전 메시지 표시, 없으면 숨김
        if let prev = undoStack.last {
            undoSnackbarMessage = prev.message
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                showUndoSnackbar = false
            }
        }
    }

    /// 그룹 Undo는 적용의 역순으로 복원해야 의존 변경도 원래 상태로 돌아갑니다.
    private func applyUndo(_ type: UndoableAction.ActionType, in context: ModelContext) {
        switch type {
        case .added(let taskIDs):
            for id in taskIDs {
                guard let task = fetchTask(id: id, in: context) else { continue }
                NotificationManager.shared.cancelNotification(for: task)
                context.delete(task)
            }

        case .deleted(let snapshots):
            for snapshot in snapshots where fetchTask(id: snapshot.id, in: context) == nil {
                let restored = snapshot.makeTask()
                context.insert(restored)
                NotificationManager.shared.scheduleNotification(for: restored)
            }

        case .updated(let previous):
            guard let task = fetchTask(id: previous.id, in: context) else { return }
            NotificationManager.shared.cancelNotification(for: task)
            previous.restore(task)
            NotificationManager.shared.scheduleNotification(for: task)

        case .toggled(let taskID, let previousState):
            guard let task = fetchTask(id: taskID, in: context) else { return }
            task.isCompleted = previousState
            if previousState {
                clearNotificationsAfterCompletion(of: task)
            } else {
                NotificationManager.shared.scheduleNotification(for: task)
            }

        case .grouped(let actions):
            for child in actions.reversed() {
                applyUndo(child, in: context)
            }
        }
    }

    func fetchTask(id: UUID, in context: ModelContext? = nil) -> AppTask? {
        guard let context = context ?? modelContext else { return nil }
        let descriptor = FetchDescriptor<AppTask>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    // MARK: - Bulk Delete (Settings)
    /// '완료한 일정 지우기' 대상: 끝난 일회성 일정만. 루틴과 반복 일정은 오늘 회차만 완료된 것이라 빼야
    /// 시리즈 전체(미래 회차 포함)가 지워지지 않습니다.
    private func isClearableCompleted(_ task: AppTask) -> Bool {
        task.isCompleted && task.category != "Routine" && !task.hasRepeatingSchedule
    }

    func completedClearableCount() -> Int {
        guard let context = modelContext else { return 0 }
        return ((try? context.fetch(FetchDescriptor<AppTask>())) ?? []).filter(isClearableCompleted).count
    }

    func deleteCompleted() {
        guard let context = modelContext else { return }
        do {
            let targets = try context.fetch(FetchDescriptor<AppTask>()).filter(isClearableCompleted)
            guard !targets.isEmpty else { return }
            let snapshots = targets.map(AppTaskSnapshot.init)
            for task in targets {
                NotificationManager.shared.cancelNotification(for: task)
                context.delete(task)
            }
            safeSave()
            setUndoAction(.deleted(snapshots), message: L.voice.undoDeleted(snapshots.count))
        } catch {
            print("completed_task_delete_failed")
        }
    }

    func deleteAll() {
        guard let context = modelContext else { return }
        do {
            let all = try context.fetch(FetchDescriptor<AppTask>())
            for task in all {
                NotificationManager.shared.cancelNotification(for: task)
                context.delete(task)
            }
            safeSave()
        } catch {
            print("all_task_delete_failed")
        }
    }

    // MARK: - Helpers

    func setUndoAction(_ type: UndoableAction.ActionType, message: String) {
        let action = UndoableAction(type: type, message: message)
        undoStack.append(action)
        // 스택 크기 제한
        if undoStack.count > Self.maxUndoDepth {
            undoStack.removeFirst()
        }

        undoSnackbarMessage = message
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            showUndoSnackbar = true
        }

        // 이전 타이머 취소 후 새 타이머 (경쟁 방지)
        undoDismissWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                self.showUndoSnackbar = false
            }
        }
        undoDismissWorkItem = workItem
        // VoiceOver로 '되돌리기'까지 찾아가려면 5초로는 부족합니다.
        let visibleSeconds: Double = UIAccessibility.isVoiceOverRunning ? 15 : 5
        DispatchQueue.main.asyncAfter(deadline: .now() + visibleSeconds, execute: workItem)
    }

    /// 이름 기반 AppTask 삭제 (배치, save 호출 안함)
    /// 매칭 전략: 정확 매칭 > 태스크명에 검색어 포함 (단, 검색어 2글자 이상일 때만)
    /// 기존 양방향 contains 제거 — "a"가 모든 태스크를 삭제하는 문제 해결
    func deleteByNameBatch(containing name: String, category: String? = nil, dateString: String? = nil) -> [AppTaskSnapshot] {
        guard let context = modelContext else { return [] }
        let descriptor = FetchDescriptor<AppTask>()
        var deleted: [AppTaskSnapshot] = []

        let query = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard query.count >= 2 else { return [] } // 1글자 검색어는 무시 (안전장치)

        do {
            let all = try context.fetch(descriptor)
            
            // 공통 날짜 파서
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            let parsedDate = (dateString != nil && dateString?.lowercased() != "all") ? formatter.date(from: dateString!) : nil

            // 1차 필터: 카테고리와 날짜 조건 먼저 검사
            let filteredAll = all.filter { item in
                if let cat = category, cat.lowercased() != "all", item.category != cat {
                    return false
                }
                if let filterDate = parsedDate {
                    if let itemDate = item.date {
                        if !Calendar.current.isDate(itemDate, inSameDayAs: filterDate) {
                            return false
                        }
                    } else {
                        return false // 날짜 조건이 있는데 대상의 날짜가 없으면 제외
                    }
                }
                return true
            }

            // 2차: 정확 매칭 (대소문자 무시)
            var matched = filteredAll.filter { $0.task.lowercased() == query }

            // 3차: 정확 매칭 없으면 → 태스크명에 검색어가 포함된 경우
            if matched.isEmpty {
                matched = filteredAll.filter { $0.task.lowercased().contains(query) }
            }

            for item in matched {
                deleted.append(AppTaskSnapshot(item))
                NotificationManager.shared.cancelNotification(for: item)
                context.delete(item)
            }
        } catch {
            print("named_task_delete_failed")
        }
        return deleted
    }

    /// insert만 수행 (save는 호출하지 않음)
    func insertBatch(_ task: AppTask) {
        guard let context = modelContext else {
            print("⚠️ TaskManager: ModelContext가 주입되지 않았습니다.")
            return
        }
        placeNewTask(task, in: context)
        context.insert(task)
        print("task_inserted category=\(task.category)")
    }

    /// 위젯 스냅샷 디바운스용 워크아이템
    private var widgetDebounceWork: DispatchWorkItem?

    /// do-catch 기반 안전한 저장. 저장까지 끝났을 때만 true.
    @discardableResult
    func safeSave() -> Bool {
        guard let context = modelContext else { return false }
        do {
            try context.save()
            // 데이터 변경 시 위젯 동기화 (디바운스: 0.5초 내 중복 호출 병합)
            widgetDebounceWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.writeWidgetSnapshot()
            }
            widgetDebounceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            return true
        } catch {
            print("task_store_save_failed")
            return false
        }
    }

    /// 한 건을 넣고 바로 저장합니다. 저장에 실패하면 넣었던 것을 되돌리고 false.
    /// 호출부는 true일 때만 알림·Undo·성공 피드백을 진행해야 합니다.
    func insertAndSave(_ task: AppTask) -> Bool {
        guard let context = modelContext else {
            print("task_store_context_missing")
            return false
        }
        placeNewTask(task, in: context)
        context.insert(task)
        guard safeSave() else {
            // 저장되지 않은 insert를 남겨두면 이후 다른 저장에 알림 없이 섞여 들어갑니다.
            context.delete(task)
            return false
        }
        return true
    }

    // MARK: - New Task Placement
    /// 새 항목을 같은 날 같은 목록의 시간 순서에 맞는 자리에 놓습니다.
    /// 순서를 한 번 바꾼 목록에서 정렬값 0이 시간과 상관없이 맨 위로 가는 것을 막습니다.
    func placeNewTask(_ task: AppTask, in context: ModelContext) {
        guard task.sortOrder == 0,
              let all = try? context.fetch(FetchDescriptor<AppTask>()) else { return }
        let day = task.date ?? Date()
        let peers = all.filter { $0.id != task.id && $0.category == task.category && $0.occursOn(day) }
        task.sortOrder = Self.placementSortOrder(forSortableTime: task.sortableTime, among: peers)
    }

    /// 화면 정렬(정렬값 → 시간)에서 시간이 더 늦은 첫 항목 바로 앞에 오는 정렬값입니다.
    /// 아무도 순서를 바꾸지 않았으면 0을 그대로 두어 시간순을 따릅니다.
    static func placementSortOrder(forSortableTime time: String, among peers: [AppTask]) -> Int {
        guard peers.contains(where: { $0.sortOrder != 0 }) else { return 0 }
        let ordered = peers.sorted { a, b in
            if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
            return a.sortableTime < b.sortableTime
        }
        // 같은 정렬값끼리는 시간순이므로, 늦은 항목과 같은 값을 쓰면 그 바로 앞에 놓입니다.
        if let later = ordered.first(where: { $0.sortableTime > time }) { return later.sortOrder }
        return (ordered.last?.sortOrder ?? 0) + 10
    }

    func taskCount(completedOnly: Bool? = nil) -> Int {
        guard let context = modelContext else { return 0 }
        do {
            let tasks = try context.fetch(FetchDescriptor<AppTask>())
            guard let completedOnly else { return tasks.count }
            return tasks.lazy.filter { $0.isCompleted == completedOnly }.count
        } catch {
            print("task_count_fetch_failed")
            return 0
        }
    }

    // MARK: - Widget Toggle Sync
    /// 위젯에서 토글된 태스크를 SwiftData에 반영합니다.
    /// 일일 초기화 앞뒤로 한 번씩 호출합니다. 큐 항목은 "scope:id:바뀐상태(1|0):누른시각(초)"이며,
    /// 예전 위젯이 남긴 "scope:id"는 뒤집기로 처리합니다.
    /// - 반복 태스크: 어제 누른 체크는 초기화 전에만(어제 칸에 기록되도록), 오늘 누른 체크는 초기화 뒤에만 반영합니다.
    /// - 반영할 때 알림도 앱 안 완료/해제와 같은 경로로 정리·재예약합니다.
    func syncWidgetToggles(now: Date = Date()) {
        guard let context = modelContext,
              let defaults = UserDefaults(suiteName: "group.trident-KR.ADHD") else { return }

        let pendingToggles = defaults.stringArray(forKey: "pendingWidgetToggles") ?? []
        guard !pendingToggles.isEmpty,
              let activeScope = AccountPreferences.activeScope else { return }

        // 처리 완료 표시 (중복 방지)
        defaults.removeObject(forKey: "pendingWidgetToggles")

        let resetPending = isDailyResetPending(now: now)
        let startOfToday = Calendar.current.startOfDay(for: now)
        var deferred: [String] = []

        do {
            let descriptor = FetchDescriptor<AppTask>()
            let allTasks = try context.fetch(descriptor)

            for scopedToggle in pendingToggles {
                let parts = scopedToggle.split(separator: ":").map(String.init)
                guard parts.count >= 2, parts[0] == activeScope,
                      let uuid = UUID(uuidString: parts[1]),
                      let task = allTasks.first(where: { $0.id == uuid }) else { continue }

                let pressedAt = parts.count >= 4 ? Double(parts[3]).map(Date.init(timeIntervalSince1970:)) : nil
                let pressedBeforeToday = pressedAt.map { $0 < startOfToday } ?? false
                if task.isRecurring || task.date == nil {
                    if pressedBeforeToday && !resetPending { continue }        // 이미 오늘로 넘어감: 어제 체크는 버림
                    if !pressedBeforeToday && resetPending {                   // 초기화 뒤에 오늘 상태로 반영
                        deferred.append(scopedToggle)
                        continue
                    }
                }

                let target = parts.count >= 3 ? parts[2] == "1" : !task.isCompleted
                guard task.isCompleted != target else { continue }
                task.isCompleted = target
                if target {
                    clearNotificationsAfterCompletion(of: task)
                } else {
                    NotificationManager.shared.scheduleNotification(for: task)
                }
            }

            try context.save()
            print("✅ 위젯 토글 \(pendingToggles.count - deferred.count)개 동기화 완료")
        } catch {
            print("widget_toggle_sync_failed")
        }

        if !deferred.isEmpty {
            let arrivedMeanwhile = defaults.stringArray(forKey: "pendingWidgetToggles") ?? []
            defaults.set(deferred + arrivedMeanwhile, forKey: "pendingWidgetToggles")
        }
    }

    // MARK: - Widget Data Sync
    /// 오늘의 태스크를 스냅샷으로 만들어 위젯과 공유합니다.
    func writeWidgetSnapshot() {
        guard let context = modelContext,
              let accountScope = AccountPreferences.activeScope else { return }
        do {
            let descriptor = FetchDescriptor<AppTask>()
            let allTasks = try context.fetch(descriptor)
            let today = Date()

            let routines = allTasks
                .filter { $0.category == "Routine" && $0.occursOn(today) }
                .sorted { $0.sortableTime < $1.sortableTime }
                .map { $0.toWidgetSnapshot() }

            let appointments = allTasks
                .filter { $0.category == "Appointment" && $0.occursOn(today) }
                .sorted { $0.sortableTime < $1.sortableTime }
                .map { $0.toWidgetSnapshot() }

            let payload = WidgetDataPayload(
                accountScope: accountScope,
                routines: routines,
                appointments: appointments,
                updatedAt: today
            )
            WidgetDataStore.write(payload)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            print("widget_snapshot_failed")
        }
    }
}
