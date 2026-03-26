import Foundation
import SwiftUI
import Combine

struct ParsedTask: Codable, Identifiable {
    var id = UUID()
    var task: String
    var time: String?
    var date: Date? // 실제 날짜 정보 추가
    let category: String // "Routine" or "Appointment"
    var isCompleted: Bool = false
    var action: String? = "add" // add, delete, update
    
    enum CodingKeys: String, CodingKey {
        case task
        case time
        case date
        case category
        case action
    }
}

class TaskManager: ObservableObject {
    @Published var routines: [ParsedTask] = [
        ParsedTask(task: "Morning Meditation", time: "07:00 AM", date: Date(), category: "Routine"),
        ParsedTask(task: "Check Email", time: "08:30 AM", date: Date(), category: "Routine"),
        ParsedTask(task: "Water Plants", time: "09:00 AM", date: Date(), category: "Routine")
    ]
    
    @Published var appointments: [ParsedTask] = [
        ParsedTask(task: "Design Sync", time: "10:00 AM", date: Date(), category: "Appointment"),
        ParsedTask(task: "Doctor Appointment", time: "2:00 PM", date: Date(), category: "Appointment"),
        ParsedTask(task: "Read Chapter 4", time: "4:30 PM", date: Date(), category: "Appointment")
    ]
    
    func process(intents: [ParsedTask]) {
        DispatchQueue.main.async {
            for intent in intents {
                let action = intent.action ?? "add"
                
                if action == "delete" {
                    print("🗑️ 삭제 요청: \(intent.task)")
                    self.routines.removeAll { $0.task.contains(intent.task) || intent.task.contains($0.task) }
                    self.appointments.removeAll { $0.task.contains(intent.task) || intent.task.contains($0.task) }
                } else {
                    // add 또는 기본값
                    print("🎯 추가 완료! [\(intent.category)] \(intent.task) (시간: \(intent.time ?? "미지정"))")
                    if intent.category == "Routine" {
                        self.routines.append(intent)
                    } else {
                        self.appointments.append(intent)
                    }
                }
            }
        }
    }
    
    func add(task: ParsedTask) {
        process(intents: [task])
    }
}
