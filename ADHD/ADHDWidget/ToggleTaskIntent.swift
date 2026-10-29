import AppIntents
import WidgetKit
import Foundation

// MARK: - Toggle Task Intent (Interactive Widget)
/// 위젯에서 직접 태스크 완료/미완료를 토글하는 AppIntent

struct ToggleTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Task"
    static var description = IntentDescription("Mark a task as complete or incomplete")
    /// 위젯 버튼 전용. 단축어·Spotlight에 '작업 ID'를 직접 입력하는 영어 동작으로 노출되지 않게 합니다.
    static var isDiscoverable: Bool = false

    @Parameter(title: "Task ID")
    var taskID: String

    init() {}

    init(taskID: String) {
        self.taskID = taskID
    }

    func perform() async throws -> some IntentResult {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: "widgetTaskPayload"),
              let payload = try? JSONDecoder().decode(WidgetDataPayload.self, from: data),
              let activeScope = WidgetAccountScope.active,
              payload.accountScope == activeScope,
              let uuid = UUID(uuidString: taskID) else {
            return .result()
        }

        let now = Date()
        // 앱이 오늘 아직 열리지 않았으면 어제 기록이 아니라 오늘 기준 상태에서 바꿉니다.
        let current = payload.normalized(for: now)

        // 스냅샷에서 해당 태스크의 완료 상태를 뒤집고, 바뀐 뒤 상태를 돌려줍니다.
        func toggle(_ tasks: inout [WidgetTaskSnapshot], id: UUID) -> Bool? {
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
                return !old.isCompleted
            }
            return nil
        }

        var routines = current.routines
        var appointments = current.appointments
        let newState = toggle(&routines, id: uuid) ?? toggle(&appointments, id: uuid)

        if let newState {
            // 미리 담아 둔 다음 날 목록은 그대로 넘겨, 자정 이후에도 그날 목록이 보이게 합니다.
            let newPayload = WidgetDataPayload(
                accountScope: current.accountScope,
                routines: routines,
                appointments: appointments,
                updatedAt: now,
                nextDay: current.nextDay
            )
            if let encoded = try? JSONEncoder().encode(newPayload) {
                defaults.set(encoded, forKey: "widgetTaskPayload")
            }

            // 메인 앱에 동기화 요청 전달 (앱 복귀 시 처리).
            // 뒤집기 대신 '바뀐 뒤 상태'와 누른 시각을 남겨, 앱이 날짜와 현재 상태를 보고 정확히 반영합니다.
            var pendingToggles = defaults.stringArray(forKey: "pendingWidgetToggles") ?? []
            pendingToggles.append("\(current.accountScope):\(taskID):\(newState ? 1 : 0):\(Int(now.timeIntervalSince1970))")
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
