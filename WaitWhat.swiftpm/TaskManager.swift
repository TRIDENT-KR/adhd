import Foundation
import SwiftData

// MARK: - ParsedTask (DTO)
/// Gemini API 응답을 디코딩하기 위한 데이터 전송 객체(DTO).
/// SwiftData @Model과 분리하여 Codable 충돌을 방지합니다.
struct ParsedTask: Codable, Identifiable {
    var id = UUID()
    var task: String
    var time: String?
    var date: Date?
    let category: String // "Routine" or "Appointment"
    var isCompleted: Bool = false

    enum CodingKeys: String, CodingKey {
        case task
        case time
        case date
        case category
    }
}

// MARK: - TaskManager
/// SwiftData ModelContext를 주입받아 AppTask의 CRUD를 담당합니다.
/// @Published 임시 배열은 완전히 제거되었으며, 모든 상태는 SwiftData가 관리합니다.
@MainActor
class TaskManager: ObservableObject {

    // 외부에서 ModelContext를 주입하기 위한 저장소
    private var modelContext: ModelContext?

    /// App.swift에서 modelContext를 주입합니다.
    func configure(context: ModelContext) {
        self.modelContext = context
    }

    // MARK: - Add Task
    /// ParsedTask(DTO)를 받아 AppTask로 변환 후 SwiftData에 저장합니다.
    func add(task dto: ParsedTask) {
        let appTask = AppTask(from: dto)
        insertAndSave(appTask)
        NotificationManager.shared.scheduleNotification(for: appTask)
    }

    // MARK: - Toggle Completion
    /// 오프라인 상태에서도 isCompleted 토글이 SwiftData에 안전하게 반영됩니다.
    func toggleCompletion(of task: AppTask) {
        task.isCompleted.toggle()
        safeSave()
    }

    // MARK: - Update Task
    /// 텍스트/시간 수정 후 호출합니다. 저장과 함께 알림을 재등록합니다.
    func update(task: AppTask) {
        safeSave()
        NotificationManager.shared.scheduleNotification(for: task)
    }

    // MARK: - Delete Task
    func delete(task: AppTask) {
        guard let context = modelContext else { return }
        context.delete(task)
        safeSave()
    }

    // MARK: - Private Helpers

    private func insertAndSave(_ task: AppTask) {
        guard let context = modelContext else {
            print("⚠️ TaskManager: ModelContext가 주입되지 않았습니다.")
            return
        }
        context.insert(task)
        safeSave()
        print("🎯 저장 완료! [\(task.category)] \(task.task) (시간: \(task.time ?? "미지정"))")
    }

    /// do-catch 기반 안전한 저장 — 오프라인/엣지 케이스 방어용
    private func safeSave() {
        guard let context = modelContext else { return }
        do {
            try context.save()
        } catch {
            print("❌ TaskManager 저장 실패: \(error.localizedDescription)")
        }
    }
}
