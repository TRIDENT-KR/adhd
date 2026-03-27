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
