import Foundation

// MARK: - Parameter Structs

struct AddSingleTaskParams: Codable {
    let task_name: String
    let time: String?
    let date: String?
    let category: String
    let recurrence: String?
}

struct UpdateTaskParams: Codable {
    let target_task_name: String
    let new_task_name: String?
    let new_time: String?
    let new_date: String?
    let new_category: String?
    let new_recurrence: String?
}

struct DeleteTaskParams: Codable {
    let target_task_name: String
}

struct ClearTasksParams: Codable {
    let target_date: String
}

struct PostponeTasksParams: Codable {
    let from_date: String
    let to_date: String
}

struct MarkTaskCompleteParams: Codable {
    let target_task_name: String
}

struct ClarificationParams: Codable {
    let reason: String
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
            let params = try container.decode(AddSingleTaskParams.self, forKey: .parameters)
            self = .addSingleTask(params)
        case "update_task":
            let params = try container.decode(UpdateTaskParams.self, forKey: .parameters)
            self = .updateTask(params)
        case "delete_specific_task":
            let params = try container.decode(DeleteTaskParams.self, forKey: .parameters)
            self = .deleteSpecificTask(params)
        case "clear_all_tasks":
            let params = try container.decode(ClearTasksParams.self, forKey: .parameters)
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
        default:
            self = .unknown(functionName)
        }
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
        case .requestClarification, .unknown: return "info"
        }
    }
    
    var uiTaskName: String {
        switch self {
        case .addSingleTask(let p): return p.task_name
        case .updateTask(let p): return p.new_task_name ?? p.target_task_name
        case .deleteSpecificTask(let p): return p.target_task_name
        case .clearAllTasks(let p): return p.target_date.lowercased() == "all" ? "모든 일정 지우기" : "\(p.target_date) 일정 일괄 지우기"
        case .postponeAllTasks(let p): return "\(p.from_date) 일정을 \(p.to_date)로 미루기"
        case .markTaskComplete(let p): return "\(p.target_task_name) 완료 처리"
        case .requestClarification(let p): return p.reason
        case .unknown(let s): return "알 수 없는 명령 (\(s))"
        }
    }
    
    var uiTime: String? {
        switch self {
        case .addSingleTask(let p): return p.time
        case .updateTask(let p): return p.new_time
        default: return nil
        }
    }
    
    var uiCategory: String {
        switch self {
        case .addSingleTask(let p): return p.category
        case .updateTask(let p): return p.new_category ?? "Routine"
        default: return "Routine"
        }
    }
}

