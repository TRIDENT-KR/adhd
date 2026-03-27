import Foundation
import SwiftData

// MARK: - SwiftData Persistent Model
/// 영구 저장소에 기록되는 실제 데이터 모델.
/// ParsedTask(DTO)와 분리하여 Codable 디코딩과의 충돌을 방지합니다.
@Model
final class AppTask {
    var id: UUID
    var task: String
    var time: String?
    var date: Date?
    var category: String   // "Routine" | "Appointment"
    var isCompleted: Bool

    init(id: UUID = UUID(),
         task: String,
         time: String? = nil,
         date: Date? = nil,
         category: String,
         isCompleted: Bool = false) {
        self.id         = id
        self.task       = task
        self.time       = time
        self.date       = date
        self.category   = category
        self.isCompleted = isCompleted
    }

    // MARK: - 정렬용 시간 키 (24시간 형식)
    /// "02:00 PM" → "14:00", "09:00 AM" → "09:00", nil → "99:99" (맨 뒤)
    var sortableTime: String {
        guard let time, !time.isEmpty else { return "99:99" }
        let trimmed = time.trimmingCharacters(in: .whitespaces)
        for formatter in Self.sortTimeFormatters {
            if let parsed = formatter.date(from: trimmed) {
                let h = Calendar.current.component(.hour, from: parsed)
                let m = Calendar.current.component(.minute, from: parsed)
                return String(format: "%02d:%02d", h, m)
            }
        }
        return time // 파싱 실패 시 원본 반환
    }

    private static let sortTimeFormatters: [DateFormatter] = {
        ["hh:mm a", "h:mm a", "HH:mm"].map { format in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            return f
        }
    }()

    // MARK: - DTO 변환 헬퍼
    /// ParsedTask(DTO) → AppTask 변환 이니셜라이저
    /// Routine은 date=nil (매일 반복), Appointment는 날짜 필수 (없으면 오늘)
    convenience init(from dto: ParsedTask) {
        let resolvedDate: Date? = dto.category == "Routine" ? nil : (dto.date ?? Date())
        self.init(
            task:     dto.task,
            time:     dto.time,
            date:     resolvedDate,
            category: dto.category
        )
    }
}
