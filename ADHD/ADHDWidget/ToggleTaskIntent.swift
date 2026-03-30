import AppIntents
import WidgetKit
import Foundation

// MARK: - Toggle Task Intent (Interactive Widget)
/// 위젯에서 직접 태스크 완료/미완료를 토글하는 AppIntent

struct ToggleTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Task"
    static var description = IntentDescription("Mark a task as complete or incomplete")

    @Parameter(title: "Task ID")
    var taskID: String

    init() {}

    init(taskID: String) {
        self.taskID = taskID
    }

    func perform() async throws -> some IntentResult {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: "widgetTaskPayload"),
              var payload = try? JSONDecoder().decode(WidgetDataPayload.self, from: data),
              let uuid = UUID(uuidString: taskID) else {
            return .result()
        }

        // 스냅샷에서 해당 태스크의 완료 상태 토글
        func toggle(_ tasks: inout [WidgetTaskSnapshot], id: UUID) -> Bool {
            if let idx = tasks.firstIndex(where: { $0.id == id }) {
                let old = tasks[idx]
                tasks[idx] = WidgetTaskSnapshot(
                    id: old.id,
                    task: old.task,
                    time: old.time,
                    category: old.category,
                    isCompleted: !old.isCompleted,
                    recurrenceLabel: old.recurrenceLabel
                )
                return true
            }
            return false
        }

        var routines = payload.routines
        var appointments = payload.appointments
        let foundInRoutines = toggle(&routines, id: uuid)
        let foundInAppointments = toggle(&appointments, id: uuid)

        if foundInRoutines || foundInAppointments {
            let newPayload = WidgetDataPayload(
                routines: routines,
                appointments: appointments,
                updatedAt: Date()
            )
            if let encoded = try? JSONEncoder().encode(newPayload) {
                defaults.set(encoded, forKey: "widgetTaskPayload")
            }

            // 메인 앱에 동기화 요청 전달 (앱 복귀 시 처리)
            var pendingToggles = defaults.stringArray(forKey: "pendingWidgetToggles") ?? []
            pendingToggles.append(taskID)
            defaults.set(pendingToggles, forKey: "pendingWidgetToggles")
        }

        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

// MARK: - Open App Intent
/// 위젯 탭 시 특정 탭으로 앱을 여는 딥링크 Intent

struct OpenRoutineIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Routines"
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        UserDefaults(suiteName: appGroupID)?.set("routine", forKey: "widgetDeepLink")
        return .result()
    }
}

struct OpenPlannerIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Planner"
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        UserDefaults(suiteName: appGroupID)?.set("planner", forKey: "widgetDeepLink")
        return .result()
    }
}

struct OpenVoiceIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Voice"
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        UserDefaults(suiteName: appGroupID)?.set("voice", forKey: "widgetDeepLink")
        return .result()
    }
}
