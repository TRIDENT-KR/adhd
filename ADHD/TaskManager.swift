import Foundation
import SwiftUI
import Combine
import SwiftData
import WidgetKit

// Removed ParsedTask

// MARK: - Undo Action
/// 되돌리기를 위한 최근 액션 저장
struct UndoableAction {
    enum ActionType {
        case added([AppTask])
        case deleted([(task: String, time: String?, date: Date?, category: String, recurrenceRule: String?)])
        case toggled(AppTask, Bool) // task, previousState
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
            checkAndResetDailyTasks()
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

    /// ISO 8601 weekday 컴포넌트 → 0=월, 1=화, … 6=일
    private func isoWeekdayIndex(of date: Date) -> Int {
        isoCalendar.component(.weekday, from: date) - 1   // iso8601: 1=Mon … 7=Sun
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
    func checkAndResetDailyTasks() {
        guard let context = modelContext else { return }
        let now = Date()
        let lastReset = UserDefaults.standard.object(forKey: lastResetKey) as? Date

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
            var resetCount = 0
            for task in routineTasks where task.isCompleted {
                task.isCompleted = false
                resetCount += 1
            }

            UserDefaults.standard.set(now, forKey: lastResetKey)
            safeSave()
            print("✅ \(resetCount)개의 태스크 초기화 완료.")
        } catch {
            print("❌ 초기화 실패: \(error.localizedDescription)")
        }
    }

    // Process logic moved to TaskManager+LLM.swift (execute method)
    
    // MARK: - Core Actions
    /// 특정 ID의 태스크를 '완료' 상태로 직접 설정 (알람 확인 시 사용)
    func completeTask(id: UUID) {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<AppTask>(predicate: #Predicate { $0.id == id })
        do {
            if let task = try context.fetch(descriptor).first {
                if !task.isCompleted {
                    task.isCompleted = true
                    safeSave()
                    print("✅ [TaskManager] 알람 확인으로 태스크 완료 처리: \(task.task)")
                    // 위젯 및 알림 갱신
                    writeWidgetSnapshot()
                    NotificationManager.shared.cancelNotification(for: task)
                }
            }
        } catch {
            print("❌ completeTask 실패: \(error.localizedDescription)")
        }
    }

    // MARK: - Toggle Completion
    func toggleCompletion(of task: AppTask) {
        let previousState = task.isCompleted
        task.isCompleted.toggle()
        safeSave()
        setUndoAction(.toggled(task, previousState), message: task.isCompleted ? L.voice.undoCompleted : L.voice.undoUncompleted)
    }

    // MARK: - Update Task
    func update(task: AppTask) {
        safeSave()
        NotificationManager.shared.scheduleNotification(for: task)
    }

    // MARK: - Delete (by reference)
    func delete(task: AppTask) {
        guard let context = modelContext else { return }
        let snapshot = (task: task.task, time: task.time, date: task.date, category: task.category, recurrenceRule: task.recurrenceRule)
        NotificationManager.shared.cancelNotification(for: task)
        context.delete(task)
        safeSave()
        setUndoAction(.deleted([snapshot]), message: L.voice.undoDeletedSingle(task.task))
    }

    // MARK: - Undo (스택 기반)
    func undo() {
        guard let action = undoStack.popLast() else { return }

        switch action.type {
        case .added(let tasks):
            guard let context = modelContext else { return }
            for task in tasks {
                NotificationManager.shared.cancelNotification(for: task)
                context.delete(task)
            }
            safeSave()

        case .deleted(let snapshots):
            for snapshot in snapshots {
                let restored = AppTask(
                    task: snapshot.task,
                    time: snapshot.time,
                    date: snapshot.date,
                    category: snapshot.category,
                    recurrenceRule: snapshot.recurrenceRule
                )
                insertBatch(restored)
                NotificationManager.shared.scheduleNotification(for: restored)
            }
            safeSave()

        case .toggled(let task, let previousState):
            task.isCompleted = previousState
            safeSave()
        }

        // 스택에 남은 항목이 있으면 이전 메시지 표시, 없으면 숨김
        if let prev = undoStack.last {
            undoSnackbarMessage = prev.message
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                showUndoSnackbar = false
            }
        }
    }

    // MARK: - Bulk Delete (Settings)
    func deleteCompleted() {
        guard let context = modelContext else { return }
        do {
            let all = try context.fetch(FetchDescriptor<AppTask>())
            for task in all where task.isCompleted && task.category != "Routine" {
                context.delete(task)
            }
            safeSave()
        } catch {
            print("❌ deleteCompleted 실패: \(error.localizedDescription)")
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
            print("❌ deleteAll 실패: \(error.localizedDescription)")
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    /// 이름 기반 AppTask 삭제 (배치, save 호출 안함)
    /// 매칭 전략: 정확 매칭 > 태스크명에 검색어 포함 (단, 검색어 2글자 이상일 때만)
    /// 기존 양방향 contains 제거 — "a"가 모든 태스크를 삭제하는 문제 해결
    func deleteByNameBatch(containing name: String, category: String? = nil, dateString: String? = nil) -> [(task: String, time: String?, date: Date?, category: String, recurrenceRule: String?)] {
        guard let context = modelContext else { return [] }
        let descriptor = FetchDescriptor<AppTask>()
        var deleted: [(task: String, time: String?, date: Date?, category: String, recurrenceRule: String?)] = []

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
                deleted.append((task: item.task, time: item.time, date: item.date, category: item.category, recurrenceRule: item.recurrenceRule))
                NotificationManager.shared.cancelNotification(for: item)
                context.delete(item)
            }
        } catch {
            print("❌ deleteByName 실패: \(error.localizedDescription)")
        }
        return deleted
    }

    /// insert만 수행 (save는 호출하지 않음)
    func insertBatch(_ task: AppTask) {
        guard let context = modelContext else {
            print("⚠️ TaskManager: ModelContext가 주입되지 않았습니다.")
            return
        }
        context.insert(task)
        print("🎯 삽입 완료! [\(task.category)] \(task.task) (시간: \(task.time ?? "미지정"))")
    }

    /// 위젯 스냅샷 디바운스용 워크아이템
    private var widgetDebounceWork: DispatchWorkItem?

    /// do-catch 기반 안전한 저장
    func safeSave() {
        guard let context = modelContext else { return }
        do {
            try context.save()
            // 데이터 변경 시 위젯 동기화 (디바운스: 0.5초 내 중복 호출 병합)
            widgetDebounceWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.writeWidgetSnapshot()
            }
            widgetDebounceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        } catch {
            print("❌ TaskManager 저장 실패: \(error.localizedDescription)")
        }
    }

    // MARK: - Widget Toggle Sync
    /// 위젯에서 토글된 태스크를 SwiftData에 반영합니다.
    func syncWidgetToggles() {
        guard let context = modelContext,
              let defaults = UserDefaults(suiteName: "group.trident-KR.ADHD") else { return }

        let pendingToggles = defaults.stringArray(forKey: "pendingWidgetToggles") ?? []
        guard !pendingToggles.isEmpty else { return }

        // 처리 완료 표시 (중복 방지)
        defaults.removeObject(forKey: "pendingWidgetToggles")

        do {
            let descriptor = FetchDescriptor<AppTask>()
            let allTasks = try context.fetch(descriptor)

            for idString in pendingToggles {
                guard let uuid = UUID(uuidString: idString),
                      let task = allTasks.first(where: { $0.id == uuid }) else { continue }
                task.isCompleted.toggle()
                print("🔄 위젯에서 토글 동기화: \(task.task) → \(task.isCompleted ? "완료" : "미완료")")
            }

            try context.save()
            print("✅ 위젯 토글 \(pendingToggles.count)개 동기화 완료")
        } catch {
            print("❌ 위젯 토글 동기화 실패: \(error.localizedDescription)")
        }
    }

    // MARK: - Widget Data Sync
    /// 오늘의 태스크를 스냅샷으로 만들어 위젯과 공유합니다.
    func writeWidgetSnapshot() {
        guard let context = modelContext else { return }
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
                routines: routines,
                appointments: appointments,
                updatedAt: today
            )
            WidgetDataStore.write(payload)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            print("❌ 위젯 스냅샷 생성 실패: \(error.localizedDescription)")
        }
    }
}
