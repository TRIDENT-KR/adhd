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
        let cleaned = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8) else { return }
        
        var parsedItems: [ParsedTask] = []
        
        do {
            // 1. 시도: 배열로 파싱 (Prompt가 요구했던 정상 형태)
            parsedItems = try JSONDecoder().decode([ParsedTask].self, from: data)
        } catch {
            print("배열 파싱 실패, 단일 객체 파싱을 시도합니다.")
            do {
                // 2. 시도: 1B 모델 특성상 단일 객체({ })로만 응답했을 경우
                let singleItem = try JSONDecoder().decode(ParsedTask.self, from: data)
                parsedItems = [singleItem]
            } catch {
                print("💥 SLM JSON 완전 파싱 실패: \\(error)")
                return
            }
        }
        
        DispatchQueue.main.async {
            print("🎯 파싱 완료! 총 \\(parsedItems.count)개의 일정이 추출되었습니다.")
            for item in parsedItems {
                print("  ✅ [\\(item.category)] \\(item.task) (시간: \\(item.time ?? "미지정"))")
                if item.category == "Routine" {
                    self.routines.append(item)
                } else if item.category == "Appointment" {
                    self.appointments.append(item)
                }
            }
        }
    }
}
