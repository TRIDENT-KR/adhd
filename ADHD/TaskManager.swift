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
    var action: String? = "add"    // main 브랜치 추가: add, delete, update

    enum CodingKeys: String, CodingKey {
        case task
        case time
        case date
        case category
        case action
    }
}

// MARK: - Undo Action
/// 되돌리기를 위한 최근 액션 저장
struct UndoableAction {
    enum ActionType {
        case added([AppTask])
        case deleted([(task: String, time: String?, date: Date?, category: String)])
        case toggled(AppTask, Bool) // task, previousState
    }
    let type: ActionType
    let timestamp: Date = Date()
}

// MARK: - TaskManager
/// SwiftData ModelContext를 주입받아 AppTask의 CRUD를 담당합니다.
@MainActor
class TaskManager: ObservableObject {

    // 외부에서 ModelContext를 주입하기 위한 저장소
    private var modelContext: ModelContext?

    // Undo 지원
    @Published var lastUndoableAction: UndoableAction?
    @Published var showUndoSnackbar = false
    @Published var undoSnackbarMessage = ""

    /// App.swift에서 modelContext를 주입합니다.
    func configure(context: ModelContext) {
        self.modelContext = context
    }

    // MARK: - Add (single)
    func add(task dto: ParsedTask) {
        process(intents: [dto])
    }

    // MARK: - Process (batch)
    /// 배치 처리: 모든 intent를 처리한 뒤 단일 save 호출
    func process(intents: [ParsedTask]) {
        var addedTasks: [AppTask] = []
        var deletedSnapshots: [(task: String, time: String?, date: Date?, category: String)] = []

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
        let snapshot = (task: task.task, time: task.time, date: task.date, category: task.category)
        NotificationManager.shared.cancelNotification(for: task)
        context.delete(task)
        safeSave()
        setUndoAction(.deleted([snapshot]), message: L.voice.undoDeletedSingle(task.task))
    }

    // MARK: - Undo
    func undo() {
        guard let action = lastUndoableAction else { return }

        switch action.type {
        case .added(let tasks):
            // 추가된 태스크들 삭제
            guard let context = modelContext else { return }
            for task in tasks {
                NotificationManager.shared.cancelNotification(for: task)
                context.delete(task)
            }
            safeSave()

        case .deleted(let snapshots):
            // 삭제된 태스크들 복원
            for snapshot in snapshots {
                let restored = AppTask(
                    task: snapshot.task,
                    time: snapshot.time,
                    date: snapshot.date,
                    category: snapshot.category
                )
                insertBatch(restored)
                NotificationManager.shared.scheduleNotification(for: restored)
            }
            safeSave()

        case .toggled(let task, let previousState):
            task.isCompleted = previousState
            safeSave()
        }

        lastUndoableAction = nil
        withAnimation(.easeOut(duration: 0.2)) {
            showUndoSnackbar = false
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
        lastUndoableAction = UndoableAction(type: type)
        undoSnackbarMessage = message
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            showUndoSnackbar = true
        }
        // 5초 후 자동 숨김
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                self.showUndoSnackbar = false
            }
            // 한 박자 뒤에 액션 삭제 (애니메이션 완료 후)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.lastUndoableAction = nil
            }
        }
    }

    /// 이름이 포함된 AppTask를 SwiftData에서 모두 삭제 (배치, save 호출 안함)
    private func deleteByNameBatch(containing name: String) -> [(task: String, time: String?, date: Date?, category: String)] {
        guard let context = modelContext else { return [] }
        let descriptor = FetchDescriptor<AppTask>()
        var deleted: [(task: String, time: String?, date: Date?, category: String)] = []
        do {
            let all = try context.fetch(descriptor)
            for item in all where item.task.contains(name) || name.contains(item.task) {
                deleted.append((task: item.task, time: item.time, date: item.date, category: item.category))
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
