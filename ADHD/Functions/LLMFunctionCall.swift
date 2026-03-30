import Foundation
import SwiftUI

/// 컨펌 모달에서 사용자가 직접 내용을 수정할 수 있도록 관리하기 위한 래퍼(Wrapper)
struct PendingLLMCall: Identifiable {
    let id = UUID()
    var call: LLMFunctionCall
    
    // UI Helpers pass-through to simplify views
    var uiAction: String { call.uiAction }
    var uiIcon: String { call.uiIcon }
    var uiActionLabel: String { call.uiActionLabel }
    var uiTaskName: String { call.uiTaskName }
    var uiTime: String? { call.uiTime }
    var uiDate: String? { call.uiDate } // Adding uiDate pass-through
    var uiCategory: String { call.uiCategory }
    var uiSmartDateRaw: String { call.uiSmartDateRaw }
    var uiSmartDateTime: String { call.uiSmartDateTime }
}


// MARK: - Parameter Structs

struct AddSingleTaskParams: Codable {
    var task_name: String
    var time: String?
    var date: String?
    var category: String
    var recurrence: String?
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
    let target_task_name: String
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
        default:
            break
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
                // 오늘 날짜인지 판별 (DateFormatter 사용)
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
            // 만약 새로 지정된 카테고리가 없으면 기본적으로 Routine으로 간주하지만, 
            // 실제 로직에서는 matchingTask의 기존 카테고리를 유지함
            return p.new_category ?? "Appointment" 
        default: return "Routine"
        }
    }
    
    // Smart Display for date and time UI
    var uiSmartDateTime: String {
        let isRoutine = (uiCategory == "Routine")
        let hasTime = (uiTime != nil && !uiTime!.isEmpty)
        let timeString = hasTime ? uiTime! : ""
        
        if isRoutine {
            // 루틴은 시간만 노출
            return timeString
        } else {
            // 일정(Appointment)은 날짜를 변환
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

