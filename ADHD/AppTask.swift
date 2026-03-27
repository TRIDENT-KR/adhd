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

    // MARK: - 반복 일정 (Lightweight migration: 새 optional 프로퍼티)
    /// 반복 규칙: "weekly" | "biweekly" | "monthly" | "yearly" | nil (일회성)
    var recurrenceRule: String?

    init(id: UUID = UUID(),
         task: String,
         time: String? = nil,
         date: Date? = nil,
         category: String,
         isCompleted: Bool = false,
         recurrenceRule: String? = nil) {
        self.id             = id
        self.task           = task
        self.time           = time
        self.date           = date
        self.category       = category
        self.isCompleted    = isCompleted
        self.recurrenceRule = recurrenceRule
    }

    /// 반복 여부
    var isRecurring: Bool { recurrenceRule != nil }

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

    // MARK: - 반복 일정: 특정 날짜에 발생하는지 판단
    /// 일회성 → date가 targetDate와 같은 날인지 확인
    /// 반복 → 시작일(date) 이후, 규칙에 따라 해당 날짜에 발생하는지 계산
    func occursOn(_ targetDate: Date) -> Bool {
        let cal = Calendar.current

        // Routine은 기존 로직 유지 (date == nil → 매일)
        guard category == "Appointment" else {
            return date == nil || cal.isDate(date!, inSameDayAs: targetDate)
        }

        guard let startDate = date else { return false }
        let target = cal.startOfDay(for: targetDate)
        let start  = cal.startOfDay(for: startDate)

        // 시작일 이전이면 불발
        guard target >= start else { return false }

        // 일회성
        guard let rule = recurrenceRule else {
            return cal.isDate(startDate, inSameDayAs: targetDate)
        }

        switch rule {
        case "weekly":
            let weeks = cal.dateComponents([.weekOfYear], from: start, to: target).weekOfYear ?? 0
            return cal.component(.weekday, from: start) == cal.component(.weekday, from: target) && weeks >= 0

        case "biweekly":
            let weeks = cal.dateComponents([.weekOfYear], from: start, to: target).weekOfYear ?? 0
            return cal.component(.weekday, from: start) == cal.component(.weekday, from: target) && weeks >= 0 && weeks % 2 == 0

        case "monthly":
            let startDay = cal.component(.day, from: start)
            let targetDay = cal.component(.day, from: target)
            let daysInMonth = cal.range(of: .day, in: .month, for: target)?.count ?? 31
            let effectiveDay = min(startDay, daysInMonth)
            return targetDay == effectiveDay && target >= start

        case "yearly":
            let startComps = cal.dateComponents([.month, .day], from: start)
            let targetComps = cal.dateComponents([.month, .day], from: target)
            return startComps.month == targetComps.month && startComps.day == targetComps.day

        default:
            return cal.isDate(startDate, inSameDayAs: targetDate)
        }
    }

    /// 반복 일정의 사람이 읽을 수 있는 라벨
    var recurrenceLabel: String? {
        guard let rule = recurrenceRule else { return nil }
        switch rule {
        case "weekly":   return L.recurrence.weekly
        case "biweekly": return L.recurrence.biweekly
        case "monthly":  return L.recurrence.monthly
        case "yearly":   return L.recurrence.yearly
        default:         return nil
        }
    }

    // MARK: - DTO 변환 헬퍼
    /// ParsedTask(DTO) → AppTask 변환 이니셜라이저
    /// Routine은 date=nil (매일 반복), Appointment는 날짜 필수 (없으면 오늘)
    convenience init(from dto: ParsedTask) {
        let resolvedDate: Date? = dto.category == "Routine" ? nil : (dto.date ?? Date())
        self.init(
            task:           dto.task,
            time:           dto.time,
            date:           resolvedDate,
            category:       dto.category,
            recurrenceRule: dto.recurrence
        )
    }
}
