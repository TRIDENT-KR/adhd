import Foundation
import SwiftUI
import Combine
import SwiftData

// MARK: - ParsedTask (DTO)
/// Gemini API 응답을 디코딩하기 위한 데이터 전송 객체(DTO).
/// SwiftData @Model과 분리하여 Codable 충돌을 방지합니다.
struct ParsedTask: Codable, Identifiable {
    var id = UUID()
    var task: String
    var time: String?
    var date: Date?
    let category: String           // "Routine" or "Appointment"
    var isCompleted: Bool = false
    var action: String? = "add"    // add, delete, update
    var recurrence: String?        // "weekly" | "biweekly" | "monthly" | "yearly" | nil

    enum CodingKeys: String, CodingKey {
        case task
        case time
        case date
        case category
        case action
        case recurrence
    }

    /// "yyyy-MM-dd" 문자열 → Date 변환을 포함한 커스텀 디코딩
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.task = try container.decode(String.self, forKey: .task)
        self.time = try container.decodeIfPresent(String.self, forKey: .time)
        self.category = try container.decode(String.self, forKey: .category)
        self.action = try container.decodeIfPresent(String.self, forKey: .action) ?? "add"

        // date: "yyyy-MM-dd" 문자열을 Date로 변환
        if let dateString = try container.decodeIfPresent(String.self, forKey: .date) {
            self.date = Self.dateFormatter.date(from: dateString)
        } else {
            self.date = nil
        }

        // recurrence 검증: 허용된 값만 통과
        if let rec = try container.decodeIfPresent(String.self, forKey: .recurrence),
           ["weekly", "biweekly", "monthly", "yearly"].contains(rec) {
            self.recurrence = rec
        } else {
            self.recurrence = nil
        }
    }

    /// 코드 내 직접 생성용 이니셜라이저
    init(task: String, time: String? = nil, date: Date? = nil, category: String, action: String? = "add", recurrence: String? = nil) {
        self.task = task
        self.time = time
        self.date = date
        self.category = category
        self.action = action
        self.recurrence = recurrence
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()
}

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
    private var modelContext: ModelContext?

    // Undo 지원 (스택 기반 — 최대 10단계)
    private var undoStack: [UndoableAction] = []
    private static let maxUndoDepth = 10
    @Published var showUndoSnackbar = false
    @Published var undoSnackbarMessage = ""
    private var undoDismissWorkItem: DispatchWorkItem?

    /// App.swift에서 modelContext를 주입합니다.
    func configure(context: ModelContext) {
        self.modelContext = context
        // 앱 구동 시 초기화 체크
        checkAndResetDailyTasks()
    }

    // MARK: - Daily Reset Logic
    private let lastResetKey = "lastResetDate"

    /// 날짜가 바뀌었는지 확인하고 루틴/반복 일정을 초기화합니다.
    func checkAndResetDailyTasks() {
        guard let context = modelContext else { return }
        let now = Date()
        let lastReset = UserDefaults.standard.object(forKey: lastResetKey) as? Date

        // 마지막 초기화 날짜가 오늘이 아니면 실행
        if lastReset == nil || !Calendar.current.isDate(lastReset!, inSameDayAs: now) {
            print("🌅 새로운 날 발견: 일일 태스크 초기화 중...")
            do {
                let descriptor = FetchDescriptor<AppTask>()
                let allTasks = try context.fetch(descriptor)

                var resetCount = 0
                for task in allTasks {
                    // 루틴이거나 반복 설정이 있는 경우만 리셋
                    if task.category == "Routine" || task.isRecurring {
                        if task.isCompleted {
                            task.isCompleted = false
                            resetCount += 1
                        }
                    }
                }

                UserDefaults.standard.set(now, forKey: lastResetKey)
                safeSave()
                print("✅ \(resetCount)개의 태스크 초기화 완료.")
            } catch {
                print("❌ 초기화 실패: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Add (single)
    func add(task dto: ParsedTask) {
        process(intents: [dto])
    }

    // MARK: - Process (batch)
    /// 배치 처리: 모든 intent를 처리한 뒤 단일 save 호출
    func process(intents: [ParsedTask]) {
        var addedTasks: [AppTask] = []
        var deletedSnapshots: [(task: String, time: String?, date: Date?, category: String, recurrenceRule: String?)] = []

        for intent in intents {
            let action = intent.action ?? "add"

            if action == "delete" {
                print("🗑️ 삭제 요청: \(intent.task)")
                let deleted = deleteByNameBatch(containing: intent.task)
                deletedSnapshots.append(contentsOf: deleted)
            } else {
                let appTask = AppTask(from: intent)
                insertBatch(appTask)
                NotificationManager.shared.scheduleNotification(for: appTask)
                addedTasks.append(appTask)
            }
        }

        // 단일 트랜잭션으로 저장
        safeSave()

        // Undo 액션 기록
        if !addedTasks.isEmpty {
            setUndoAction(.added(addedTasks), message: L.voice.undoAdded(addedTasks.count))
        } else if !deletedSnapshots.isEmpty {
            setUndoAction(.deleted(deletedSnapshots), message: L.voice.undoDeleted(deletedSnapshots.count))
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
            for task in all where task.isCompleted {
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

    // MARK: - Private Helpers

    private func setUndoAction(_ type: UndoableAction.ActionType, message: String) {
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
    private func deleteByNameBatch(containing name: String) -> [(task: String, time: String?, date: Date?, category: String, recurrenceRule: String?)] {
        guard let context = modelContext else { return [] }
        let descriptor = FetchDescriptor<AppTask>()
        var deleted: [(task: String, time: String?, date: Date?, category: String, recurrenceRule: String?)] = []

        let query = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard query.count >= 2 else { return [] } // 1글자 검색어는 무시 (안전장치)

        do {
            let all = try context.fetch(descriptor)

            // 1차: 정확 매칭 (대소문자 무시)
            var matched = all.filter { $0.task.lowercased() == query }

            // 2차: 정확 매칭 없으면 → 태스크명에 검색어가 포함된 경우
            if matched.isEmpty {
                matched = all.filter { $0.task.lowercased().contains(query) }
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
    private func insertBatch(_ task: AppTask) {
        guard let context = modelContext else {
            print("⚠️ TaskManager: ModelContext가 주입되지 않았습니다.")
            return
        }
        context.insert(task)
        print("🎯 삽입 완료! [\(task.category)] \(task.task) (시간: \(task.time ?? "미지정"))")
    }

    /// do-catch 기반 안전한 저장
    private func safeSave() {
        guard let context = modelContext else { return }
        do {
            try context.save()
        } catch {
            print("❌ TaskManager 저장 실패: \(error.localizedDescription)")
        }
    }
}
