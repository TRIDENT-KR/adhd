import Foundation

struct ParsedTask: Codable, Identifiable {
    var id = UUID()
    var task: String
    var time: String?
    let category: String // "Routine" or "Appointment"
    var isCompleted: Bool = false
    
    enum CodingKeys: String, CodingKey {
        case task
        case time
        case category
    }
}

class TaskManager: ObservableObject {
    @Published var routines: [ParsedTask] = [
        ParsedTask(task: "Morning Meditation", time: "07:00 AM", category: "Routine"),
        ParsedTask(task: "Check Email", time: "08:30 AM", category: "Routine"),
        ParsedTask(task: "Water Plants", time: "09:00 AM", category: "Routine")
    ]
    
    @Published var appointments: [ParsedTask] = [
        ParsedTask(task: "Design Sync", time: "10:00 AM", category: "Appointment"),
        ParsedTask(task: "Doctor Appointment", time: "2:00 PM", category: "Appointment"),
        ParsedTask(task: "Read Chapter 4", time: "4:30 PM", category: "Appointment")
    ]
    
    func add(task: ParsedTask) {
        DispatchQueue.main.async {
            print("🎯 처리 완료! 추가된 일정: [\(task.category)] \(task.task) (시간: \(task.time ?? "미지정"))")
            if task.category == "Routine" {
                self.routines.append(task)
            } else if task.category == "Appointment" {
                self.appointments.append(task)
            }
        }
    }
}
