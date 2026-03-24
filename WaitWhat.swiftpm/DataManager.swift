import SwiftData
import Foundation

@Model
class RoutineTask {
    @Attribute(.unique) var id: UUID
    var title: String
    var time: String
    var isCompleted: Bool
    
    init(id: UUID = UUID(), title: String, time: String, isCompleted: Bool = false) {
        self.id = id
        self.title = title
        self.time = time
        self.isCompleted = isCompleted
    }
}

@Model
class PlannerEvent {
    @Attribute(.unique) var id: UUID
    var title: String
    var date: Date
    
    init(id: UUID = UUID(), title: String, date: Date) {
        self.id = id
        self.title = title
        self.date = date
    }
}

class DataManager {
    static let shared = DataManager()
    
    private init() {}
    
    func insert(parsedResult: AIManager.AIParsedResult, context: ModelContext) {
        switch parsedResult.category {
        case "routine":
            let taskTitle = parsedResult.task
            let taskTime = parsedResult.time ?? "00:00"
            let newTask = RoutineTask(title: taskTitle, time: taskTime)
            context.insert(newTask)
            print("Successfully inserted RoutineTask: \\(taskTitle)")
            
        case "planner":
            let eventTitle = parsedResult.task
            let dateStr = parsedResult.datetime ?? ""
            let formatter = ISO8601DateFormatter()
            let eventDate = formatter.date(from: dateStr) ?? Date()
            
            let newEvent = PlannerEvent(title: eventTitle, date: eventDate)
            context.insert(newEvent)
            print("Successfully inserted PlannerEvent: \\(eventTitle)")
            
        default:
            print("Unknown category: \\(parsedResult.category)")
        }
    }
}
