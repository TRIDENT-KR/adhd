import Foundation

struct ParsedTask: Codable, Identifiable {
    var id = UUID()
    let task: String
    let time: String?
    let category: String // "Routine" or "Appointment"
    
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
    
    func ingest(jsonString: String) {
        guard let data = jsonString.data(using: .utf8) else { return }
        do {
            let items = try JSONDecoder().decode([ParsedTask].self, from: data)
            DispatchQueue.main.async {
                print("🎯 파싱 완료! 총 \(items.count)개의 일정이 추출되었습니다.")
                for item in items {
                    print("  ✅ [\(item.category)] \(item.task) (시간: \(item.time ?? "미지정"))")
                    if item.category == "Routine" {
                        self.routines.append(item)
                    } else if item.category == "Appointment" {
                        self.appointments.append(item)
                    }
                }
            }
        } catch {
            print("Failed to decode SLM JSON: \(error)")
            // Fallback for missing array brackets or simple single object
            if let singleItem = try? JSONDecoder().decode(ParsedTask.self, from: data) {
                DispatchQueue.main.async {
                    if singleItem.category == "Routine" {
                        self.routines.append(singleItem)
                    } else if singleItem.category == "Appointment" {
                        self.appointments.append(singleItem)
                    }
                }
            }
        }
    }
}
