import Foundation
import SwiftUI

/// 컨펌 모달에서 사용자가 직접 내용을 수정할 수 있도록 관리하기 위한 래퍼(Wrapper)
struct PendingLLMCall: Identifiable {
    let id = UUID()
    var call: LLMFunctionCall
    var urgency: Urgency
    /// nil은 아직 승인용 대상이 고정되지 않았다는 뜻이고, 빈 배열은 고정했지만 대상이 0개라는 뜻입니다.
    var targetSnapshots: [AppTaskSnapshot]?
    var executionIssue: LLMExecutionIssue?
    /// stale 감지 후 최신 미리보기를 다시 보여준 경우, 다음 확인 전에는 실행하지 않습니다.
    var requiresReconfirmation = false

    init(call: LLMFunctionCall) {
        self.call = call
        self.urgency = Self.defaultUrgency(for: call)
        self.targetSnapshots = call.requiresPreparedTargets ? nil : []
        self.executionIssue = nil
    }

    mutating func invalidatePreparedTargets() {
        guard call.requiresPreparedTargets else { return }
        targetSnapshots = nil
        executionIssue = nil
        requiresReconfirmation = true
    }

    /// 하이브리드 urgency 분류:
    /// 1) LLM이 판단한 urgency가 있으면 그대로 채택
    /// 2) 없거나 이상값이면 휴리스틱 — Appointment(일회성 약속)=strong, Routine(습관)=weak
    /// 3) 최종 오버라이드는 확인 카드의 bolt 토글 (사용자)
    static func defaultUrgency(for call: LLMFunctionCall) -> Urgency {
        guard case .addSingleTask(let params) = call else { return .strong }
        if let raw = params.urgency, let parsed = Urgency(rawValue: raw) {
            return parsed
        }
        return params.category == "Appointment" ? .strong : .weak
    }

    // UI Helpers pass-through to simplify views
    var uiAction: String { call.uiAction }
    var uiIcon: String { call.uiIcon }
    var uiActionLabel: String { call.uiActionLabel }
    var uiTaskName: String { call.uiTaskName }
    var uiTime: String? { call.uiTime }
    var uiDate: String? { call.uiDate }
    var uiCategory: String { call.uiCategory }
    var uiSmartDateRaw: String { call.uiSmartDateRaw }
    var uiSmartDateTime: String { call.uiSmartDateTime }
}

enum LLMExecutionIssue: Equatable {
    case invalidCommand
    case confirmationRequired
    case storeUnavailable
    case previewRequired
    case noMatchingTarget
    case staleTarget
    case persistenceFailed
    case notExecutedAfterStoreFailure
    case unsupportedCommand
}


// MARK: - Parameter Structs

struct AddSingleTaskParams: Codable {
    var task_name: String
    var time: String?
    var date: String?
    var category: String
    var recurrence: String?
    /// LLM이 판단한 알림 강도: "strong" | "weak" | nil (하이브리드 분류 1단계)
    var urgency: String?
}

struct UpdateTaskParams: Codable {
    var target_task_name: String
    var new_task_name: String?
    var new_time: String?
    var new_date: String?
    var new_category: String?
    var new_recurrence: String?
}

struct DeleteTaskParams: Codable {
    var target_task_name: String
    var target_category: String?
    var target_date: String?
}

struct ClearTasksParams: Codable {
    var target_category: String?
    var target_date: String
}

struct PostponeTasksParams: Codable {
    let from_date: String
    let to_date: String
}

struct MarkTaskCompleteParams: Codable {
    var target_task_name: String
}

struct ClarificationParams: Codable {
    let reason: String
}

/// OOV(Out-of-Domain) 응답 파라미터: 앱 목적과 무관한 입력에 대한 재치 있는 응답 메시지
struct OffTopicChatParams: Codable {
    let message: String
}

// MARK: - LLMFunctionCall Router Enum

enum LLMFunctionCall: Decodable {
    case addSingleTask(AddSingleTaskParams)
    case updateTask(UpdateTaskParams)
    case deleteSpecificTask(DeleteTaskParams)
    case clearAllTasks(ClearTasksParams)
    case postponeAllTasks(PostponeTasksParams)
    case markTaskComplete(MarkTaskCompleteParams)
    case requestClarification(ClarificationParams)
    case handleOffTopicChat(OffTopicChatParams) // OOV 예외 처리
    case unknown(String) // Fallback for unsupported functions

    enum CodingKeys: String, CodingKey {
        case function_name
        case parameters
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let functionName = try container.decode(String.self, forKey: .function_name)

        switch functionName {
        case "add_single_task":
            var params = try container.decode(AddSingleTaskParams.self, forKey: .parameters)
            params.category = (params.category.lowercased() == "appointment") ? "Appointment" : "Routine"
            self = .addSingleTask(params)
        case "update_task":
            var params = try container.decode(UpdateTaskParams.self, forKey: .parameters)
            if let cat = params.new_category {
                params.new_category = (cat.lowercased() == "appointment") ? "Appointment" : "Routine"
            }
            self = .updateTask(params)
        case "delete_specific_task":
            var params = try container.decode(DeleteTaskParams.self, forKey: .parameters)
            if let cat = params.target_category {
                switch cat.lowercased() {
                case "appointment": params.target_category = "Appointment"
                case "routine": params.target_category = "Routine"
                case "all": params.target_category = "all"
                default:
                    throw DecodingError.dataCorruptedError(
                        forKey: .parameters,
                        in: container,
                        debugDescription: "Invalid delete target category"
                    )
                }
            }
            self = .deleteSpecificTask(params)
        case "clear_all_tasks":
            var params = try container.decode(ClearTasksParams.self, forKey: .parameters)
            if let cat = params.target_category {
                switch cat.lowercased() {
                case "appointment": params.target_category = "Appointment"
                case "routine": params.target_category = "Routine"
                case "all": params.target_category = "all"
                default:
                    throw DecodingError.dataCorruptedError(
                        forKey: .parameters,
                        in: container,
                        debugDescription: "Invalid clear target category"
                    )
                }
            }
            self = .clearAllTasks(params)
        case "postpone_all_tasks":
            let params = try container.decode(PostponeTasksParams.self, forKey: .parameters)
            self = .postponeAllTasks(params)
        case "mark_task_complete":
            let params = try container.decode(MarkTaskCompleteParams.self, forKey: .parameters)
            self = .markTaskComplete(params)
        case "request_clarification":
            let params = try container.decode(ClarificationParams.self, forKey: .parameters)
            self = .requestClarification(params)
        case "handle_off_topic_chat":
            let params = try container.decode(OffTopicChatParams.self, forKey: .parameters)
            self = .handleOffTopicChat(params)
        default:
            self = .unknown(functionName)
        }
    }

    mutating func updateFields(taskName: String, time: String?, date: String?, category: String) {
        let isRoutine = (category == "Routine")
        // 루틴은 날짜 정보가 있으면 안 됨 (매일 반복이 기본이므로)
        let finalDate = isRoutine ? nil : date
        
        switch self {
        case .addSingleTask(var p):
            p.task_name = taskName
            p.time = time
            p.date = finalDate
            p.category = category
            self = .addSingleTask(p)
        case .updateTask(var p):
            p.new_task_name = taskName
            p.new_time = time
            p.new_date = finalDate
            p.new_category = category
            self = .updateTask(p)
        case .deleteSpecificTask(var p):
            p = DeleteTaskParams(
                target_task_name: taskName,
                target_category: category,
                target_date: finalDate
            )
            self = .deleteSpecificTask(p)
        case .markTaskComplete:
            self = .markTaskComplete(MarkTaskCompleteParams(target_task_name: taskName))
        default:
            break
        }
    }

    /// 대상 없음으로 실패한 카드에서 사용자가 검색 대상을 직접 고칠 때 사용합니다.
    mutating func retargetForRetry(
        taskName: String,
        date: String?,
        category: String
    ) {
        switch self {
        case .updateTask(var params):
            params.target_task_name = taskName
            self = .updateTask(params)
        case .deleteSpecificTask(var params):
            params.target_task_name = taskName
            params.target_category = category
            params.target_date = category == "Routine" ? nil : date
            self = .deleteSpecificTask(params)
        case .markTaskComplete(var params):
            params.target_task_name = taskName
            self = .markTaskComplete(params)
        default:
            break
        }
    }
    
    /// OOV 응답 여부
    var isOffTopic: Bool {
        if case .handleOffTopicChat = self { return true }
        return false
    }
    
    /// OOV 응답 메시지 추출
    var offTopicMessage: String? {
        if case .handleOffTopicChat(let p) = self { return p.message }
        return nil
    }

    /// 사용자 설정과 무관하게 명시적 확인이 필요한 단일 명령입니다.
    var requiresExplicitConfirmation: Bool {
        switch self {
        case .deleteSpecificTask, .clearAllTasks, .postponeAllTasks:
            return true
        default:
            return false
        }
    }

    /// 기존 데이터를 바꾸는 명령은 승인 화면을 열 때 정확한 UUID/상태 스냅샷을 고정합니다.
    var requiresPreparedTargets: Bool {
        switch self {
        case .updateTask, .deleteSpecificTask, .clearAllTasks, .postponeAllTasks, .markTaskComplete:
            return true
        case .addSingleTask, .requestClarification, .handleOffTopicChat, .unknown:
            return false
        }
    }

    /// 한 응답에 여러 개가 포함되면 대량 변경으로 취급할 명령입니다.
    fileprivate var isMutableExistingTaskCommand: Bool {
        switch self {
        case .updateTask, .markTaskComplete:
            return true
        default:
            return false
        }
    }

    /// LLM이 범위를 누락하거나 잘못 보낸 명령은 넓은 범위로 보정하지 않고 실행을 차단합니다.
    var isExecutionPayloadValid: Bool {
        switch self {
        case .addSingleTask(let params):
            return !params.task_name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && Self.isValidCategory(params.category, allowsAll: false)
                && Self.isValidDate(params.date, allowsNil: true, allowsAll: false)
        case .updateTask(let params):
            return !params.target_task_name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && [
                    params.new_task_name,
                    params.new_time,
                    params.new_date,
                    params.new_category,
                    params.new_recurrence,
                ].contains(where: { $0 != nil })
                && Self.isValidCategory(params.new_category, allowsAll: false)
                && Self.isValidDate(params.new_date, allowsNil: true, allowsAll: false)
        case .deleteSpecificTask(let params):
            return params.target_task_name.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
                && Self.isValidCategory(params.target_category, allowsAll: true)
                && Self.isValidDate(params.target_date, allowsNil: true, allowsAll: true)
        case .clearAllTasks(let params):
            return Self.isValidCategory(params.target_category, allowsAll: true)
                && Self.isValidDate(params.target_date, allowsNil: false, allowsAll: true)
        case .postponeAllTasks(let params):
            return Self.isValidDate(params.from_date, allowsNil: false, allowsAll: false)
                && Self.isValidDate(params.to_date, allowsNil: false, allowsAll: false)
        case .markTaskComplete(let params):
            return !params.target_task_name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .requestClarification(let params):
            return !params.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .handleOffTopicChat(let params):
            return !params.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .unknown:
            return false
        }
    }

    private static func isValidCategory(_ value: String?, allowsAll: Bool) -> Bool {
        guard let value else { return true }
        return value == "Routine" || value == "Appointment" || (allowsAll && value.lowercased() == "all")
    }

    private static func isValidDate(
        _ value: String?,
        allowsNil: Bool,
        allowsAll: Bool
    ) -> Bool {
        guard let value else { return allowsNil }
        if allowsAll && value.lowercased() == "all" { return true }

        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return false
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { return false }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        return resolved.year == year && resolved.month == month && resolved.day == day
    }

    var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }
}

enum LLMConfirmationPolicy {
    static func requiresExplicitConfirmation(for calls: [LLMFunctionCall]) -> Bool {
        if calls.contains(where: \.requiresExplicitConfirmation) {
            return true
        }

        return calls.filter(\.isMutableExistingTaskCommand).count > 1
    }
}

// MARK: - UI Helpers for Confirmation Card
extension LLMFunctionCall: Identifiable {
    var id: UUID { UUID() }
    
    var uiAction: String {
        switch self {
        case .deleteSpecificTask, .clearAllTasks: return "delete"
        case .addSingleTask: return "add"
        case .updateTask, .postponeAllTasks, .markTaskComplete: return "update"
        case .requestClarification, .handleOffTopicChat, .unknown: return "info"
        }
    }
    
    var uiIcon: String {
        switch uiAction {
        case "delete": return "trash.circle.fill"
        case "update": return "pencil.circle.fill"
        case "add":
            return CategoryIconResolver.resolveIcon(for: uiTaskName, category: uiCategory)
        default:
            return "plus.circle.fill"
        }
    }
    
    var uiActionLabel: String {
        switch uiAction {
        case "delete": return L.voice.confirmDelete
        case "update": return L.voice.confirmUpdate
        default:
            if uiCategory == "Appointment" {
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd"
                let todayString = df.string(from: Date())
                if uiDate == todayString {
                    return L.voice.confirmTask
                }
                return L.voice.confirmAppointment
            }
            return L.voice.confirmRoutine
        }
    }
    
    var uiTaskName: String {
        switch self {
        case .addSingleTask(let p): return p.task_name
        case .updateTask(let p): return p.new_task_name ?? p.target_task_name
        case .deleteSpecificTask(let p): return p.target_task_name
        case .clearAllTasks(let p):
            return p.target_date.lowercased() == "all" ? L.voice.actionClearAll : L.voice.actionClearDate(p.target_date)
        case .postponeAllTasks(let p): return L.voice.actionPostpone(from: p.from_date, to: p.to_date)
        case .markTaskComplete(let p): return L.voice.actionComplete(p.target_task_name)
        case .requestClarification(let p): return p.reason
        case .handleOffTopicChat(let p): return p.message
        case .unknown(let s): return L.voice.actionUnknown(s)
        }
    }
    
    var uiTime: String? {
        switch self {
        case .addSingleTask(let p): return p.time
        case .updateTask(let p): return p.new_time
        default: return nil
        }
    }
    
    var uiDate: String? {
        switch self {
        case .addSingleTask(let p): return p.date
        case .updateTask(let p): return p.new_date
        case .deleteSpecificTask(let p): return p.target_date
        default: return nil
        }
    }
    
    var uiSmartDateRaw: String {
        uiDate ?? ""
    }
    
    var uiCategory: String {
        switch self {
        case .addSingleTask(let p): return p.category
        case .updateTask(let p):
            return p.new_category ?? "Appointment"
        case .deleteSpecificTask(let p):
            if p.target_category == "Routine" { return "Routine" }
            if p.target_category == "Appointment" { return "Appointment" }
            if let targetDate = p.target_date, targetDate.lowercased() != "all" { return "Appointment" }
            return "All"
        default: return "Routine"
        }
    }
    
    // Smart Display for date and time UI
    var uiSmartDateTime: String {
        let isRoutine = (uiCategory == "Routine")
        let hasTime = (uiTime != nil && !uiTime!.isEmpty)
        let timeString = hasTime ? uiTime! : ""
        
        if isRoutine {
            return timeString
        } else {
            guard let dateString = uiDate, !dateString.isEmpty else { return timeString }
            
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            let todayString = df.string(from: Date())
            
            let datePrefix = (dateString == todayString) ? L.voice.confirmToday : dateString
            
            if hasTime {
                return "\(datePrefix) \(timeString)"
            } else {
                return datePrefix
            }
        }
    }
}
