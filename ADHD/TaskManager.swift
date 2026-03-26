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

    // MARK: - Add (single)
    /// ParsedTask(DTO)를 받아 AppTask로 변환 후 SwiftData에 저장합니다.
    func add(task dto: ParsedTask) {
        process(intents: [dto])
    }

    // MARK: - Process (batch)
    /// main 브랜치의 action 기반 배치 처리 로직을 SwiftData에 통합합니다.
    /// - "delete": 이름이 포함된 AppTask를 SwiftData에서 삭제
    /// - "add" 또는 기타: AppTask로 변환 후 insert
    func process(intents: [ParsedTask]) {
        for intent in intents {
            let action = intent.action ?? "add"

            if action == "delete" {
                print("🗑️ 삭제 요청: \(intent.task)")
                deleteByName(containing: intent.task)
            } else {
                // add or update
                let appTask = AppTask(from: intent)
                insertAndSave(appTask)
                NotificationManager.shared.scheduleNotification(for: appTask)
            }
        }
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

    // MARK: - Delete (by reference)
    func delete(task: AppTask) {
        guard let context = modelContext else { return }
        context.delete(task)
        safeSave()
    }

    // MARK: - Bulk Delete (Settings)
    /// 완료된 태스크만 일괄 삭제
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

    /// 모든 태스크 일괄 삭제
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

    /// 이름이 포함된 AppTask를 SwiftData에서 모두 삭제합니다. (action == "delete" 전용)
    private func deleteByName(containing name: String) {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<AppTask>()
        do {
            let all = try context.fetch(descriptor)
            for item in all where item.task.contains(name) || name.contains(item.task) {
                context.delete(item)
            }
            safeSave()
        } catch {
            print("❌ deleteByName 실패: \(error.localizedDescription)")
        }
    }

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
