import Foundation

// MARK: - App Group Identifier
/// 메인 앱과 위젯 간 데이터 공유를 위한 App Group ID
let appGroupID = "group.trident-KR.ADHD"

// MARK: - Widget Task Snapshot (Lightweight DTO)
/// 위젯에 표시할 태스크의 경량 스냅샷 (SwiftData 의존성 없음)
struct WidgetTaskSnapshot: Codable, Identifiable {
    let id: UUID
    let task: String
    let time: String?
    let category: String       // "Routine" | "Appointment"
    let isCompleted: Bool
    let recurrenceLabel: String?

    /// 정렬용 24시간 형식 시간 키
    var sortableTime: String {
        guard let time, !time.isEmpty else { return "99:99" }
        let trimmed = time.trimmingCharacters(in: .whitespaces)
        for format in ["hh:mm a", "h:mm a", "HH:mm"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            if let parsed = f.date(from: trimmed) {
                let h = Calendar.current.component(.hour, from: parsed)
                let m = Calendar.current.component(.minute, from: parsed)
                return String(format: "%02d:%02d", h, m)
            }
        }
        return time
    }
}

// MARK: - Widget Data Payload
/// 위젯에 전달하는 전체 데이터 패킷
struct WidgetDataPayload: Codable {
    let routines: [WidgetTaskSnapshot]
    let appointments: [WidgetTaskSnapshot]
    let updatedAt: Date

    /// 오늘의 모든 미완료 태스크 (시간순 정렬)
    var allPendingTasks: [WidgetTaskSnapshot] {
        (routines + appointments)
            .filter { !$0.isCompleted }
            .sorted { $0.sortableTime < $1.sortableTime }
    }

    /// 루틴 완료율
    var routineProgress: (completed: Int, total: Int) {
        (routines.filter(\.isCompleted).count, routines.count)
    }
}
