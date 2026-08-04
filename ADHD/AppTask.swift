import Foundation
import SwiftData

// MARK: - Urgency
/// 알림 강도: weak = 일반 배너, strong = 시간 민감형 + 앱 내 풀스크린 오버레이
public enum Urgency: String, Codable {
    case weak   = "weak"
    case strong = "strong"
}

// MARK: - Recurrence Engine
/// 최초 기준일(anchor)에서 반복 발생일을 계산하는 순수 Foundation 엔진입니다.
/// 계산 결과를 다음 기준일로 저장하지 않으므로 완료가 늦어져도 반복 주기가 밀리지 않습니다.
enum RecurrenceEngine {
    private static let oneShotRules = Set(["biweekly", "monthly", "yearly"])

    static func requiresOneShotNotification(_ rule: String?) -> Bool {
        guard let rule else { return false }
        return oneShotRules.contains(rule)
    }

    static func occurs(
        on targetDate: Date,
        anchor: Date,
        rule: String,
        calendar: Calendar = .current
    ) -> Bool {
        let target = calendar.startOfDay(for: targetDate)
        let start = calendar.startOfDay(for: anchor)
        guard target >= start else { return false }

        switch rule {
        case "weekly", "biweekly":
            guard let elapsedDays = calendar.dateComponents(
                [.day], from: start, to: target
            ).day else { return false }
            let interval = rule == "weekly" ? 7 : 14
            return elapsedDays % interval == 0

        case "monthly":
            let startParts = calendar.dateComponents([.year, .month, .day], from: start)
            let targetParts = calendar.dateComponents([.year, .month, .day], from: target)
            guard let startYear = startParts.year,
                  let startMonth = startParts.month,
                  let startDay = startParts.day,
                  let targetYear = targetParts.year,
                  let targetMonth = targetParts.month,
                  let targetDay = targetParts.day else { return false }

            let elapsedMonths = (targetYear - startYear) * 12 + targetMonth - startMonth
            guard elapsedMonths >= 0,
                  let daysInTargetMonth = calendar.range(
                    of: .day, in: .month, for: target
                  )?.count else { return false }
            return targetDay == min(startDay, daysInTargetMonth)

        case "yearly":
            let startParts = calendar.dateComponents([.year, .month, .day], from: start)
            let targetParts = calendar.dateComponents([.year, .month, .day], from: target)
            guard let startYear = startParts.year,
                  let startMonth = startParts.month,
                  let startDay = startParts.day,
                  let targetYear = targetParts.year,
                  let targetMonth = targetParts.month,
                  let targetDay = targetParts.day,
                  targetYear >= startYear,
                  targetMonth == startMonth,
                  let daysInTargetMonth = calendar.range(
                    of: .day, in: .month, for: target
                  )?.count else { return false }
            return targetDay == min(startDay, daysInTargetMonth)

        default:
            return calendar.isDate(anchor, inSameDayAs: targetDate)
        }
    }

    /// 지정한 현지 날짜의 wall-clock 시각을 만듭니다.
    /// DST로 시각이 사라지면 다음 유효 시각, 두 번 나타나면 첫 번째 시각을 선택합니다.
    static func wallClockDate(
        on day: Date,
        hour: Int,
        minute: Int,
        calendar: Calendar = .current
    ) -> Date? {
        calendar.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: calendar.startOfDay(for: day),
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }

    /// 격주·월간·연간 알림에 사용할 미래 최초 1건을 반환합니다.
    /// `leadMinutes`는 실제 발생 wall-clock 시각에서 차감합니다.
    static func nextScheduledDate(
        after now: Date,
        anchor: Date,
        rule: String,
        hour: Int,
        minute: Int,
        leadMinutes: Int = 0,
        calendar: Calendar = .current
    ) -> Date? {
        guard requiresOneShotNotification(rule) else { return nil }

        let today = calendar.startOfDay(for: now)
        let anchorDay = calendar.startOfDay(for: anchor)
        let searchStart = max(today, anchorDay)

        // 세 규칙 모두 1년 안에 다음 발생일이 반드시 있으므로 윤년 여유를 포함해 탐색합니다.
        for offset in 0...370 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: searchStart),
                  occurs(on: day, anchor: anchor, rule: rule, calendar: calendar),
                  let occurrence = wallClockDate(
                    on: day, hour: hour, minute: minute, calendar: calendar
                  ),
                  let fireDate = calendar.date(
                    byAdding: .minute, value: -leadMinutes, to: occurrence
                  ) else { continue }
            if fireDate > now { return fireDate }
        }
        return nil
    }
}

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

    /// 알림 강도 (SwiftData @Model은 enum 기본값을 직접 지원하지 않으므로 String으로 저장)
    var urgencyRaw: String = Urgency.strong.rawValue
    var urgency: Urgency {
        get { Urgency(rawValue: urgencyRaw) ?? .strong }
        set { urgencyRaw = newValue.rawValue }
    }

    /// 사용자 지정 정렬 순서 (0 = 미지정, 낮을수록 위에 표시)
    var sortOrder: Int = 0

    /// 이번 주 요일별 완료 여부 (ISO 8601 기준: 0=월, 1=화, 2=수, 3=목, 4=금, 5=토, 6=일)
    /// Lightweight migration: 기존 레코드는 SwiftData가 기본값([false×7])으로 채움
    var weeklyCompletions: [Bool] = Array(repeating: false, count: 7)

    init(id: UUID = UUID(),
         task: String,
         time: String? = nil,
         date: Date? = nil,
         category: String,
         isCompleted: Bool = false,
         recurrenceRule: String? = nil,
         sortOrder: Int = 0,
         urgency: Urgency = .strong) {
        self.id             = id
        self.task           = task
        self.time           = time
        self.date           = date
        self.category       = category
        self.isCompleted    = isCompleted
        self.recurrenceRule = recurrenceRule
        self.sortOrder      = sortOrder
        self.urgencyRaw     = urgency.rawValue
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
    func occursOn(_ targetDate: Date, calendar: Calendar = .current) -> Bool {
        let cal = calendar

        // Routine은 기존 로직 유지 (date == nil → 매일)
        guard category == "Appointment" else {
            return date == nil || cal.isDate(date!, inSameDayAs: targetDate)
        }

        guard let startDate = date else { return false }
        // 일회성
        guard let rule = recurrenceRule else {
            return cal.isDate(startDate, inSameDayAs: targetDate)
        }
        return RecurrenceEngine.occurs(
            on: targetDate,
            anchor: startDate,
            rule: rule,
            calendar: cal
        )
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

    // MARK: - Widget Snapshot 변환
    /// 위젯용 경량 DTO로 변환
    func toWidgetSnapshot() -> WidgetTaskSnapshot {
        WidgetTaskSnapshot(
            id: id,
            task: task,
            time: time,
            category: category,
            isCompleted: isCompleted,
            recurrenceLabel: recurrenceLabel
        )
    }
}

public struct CategoryIconResolver {
    /// 태스크명에서 키워드 매칭으로 카테고리 아이콘 결정 (Visual Anchor)
    /// 영어 / 한국어 / 일본어 키워드 지원
    public static let iconRules: [(icon: String, keywords: [String])] = [
        ("figure.run",              ["exercise", "workout", "run", "gym", "jog",
                                     "운동", "달리기", "조깅", "헬스",
                                     "運動", "ランニング", "ジョギング", "ジム"]),
        ("pill.fill",               ["medicine", "pill", "drug", "vitamin", "supplement",
                                     "약", "비타민", "영양제", "복용",
                                     "薬", "ビタミン", "サプリ", "服薬"]),
        ("fork.knife",              ["meal", "eat", "breakfast", "lunch", "dinner", "cook", "food",
                                     "식사", "밥", "아침", "점심", "저녁", "요리", "먹",
                                     "食事", "ご飯", "朝食", "昼食", "夕食", "料理"]),
        ("alarm.fill",              ["sleep", "bed", "wake", "alarm",
                                     "잠", "수면", "기상", "알람", "일어나",
                                     "睡眠", "寝", "起き", "アラーム", "起床"]),
        ("book.fill",               ["study", "read", "book", "learn", "homework",
                                     "공부", "독서", "책", "학습", "숙제",
                                     "勉強", "読書", "本", "学習", "宿題"]),
        ("phone.fill",              ["meeting", "call", "zoom", "conference",
                                     "회의", "전화", "미팅", "통화",
                                     "会議", "電話", "ミーティング", "通話"]),
        ("bubbles.and.sparkles.fill", ["clean", "laundry", "wash", "tidy",
                                     "청소", "빨래", "세탁", "정리",
                                     "掃除", "洗濯", "片付け"]),
        ("pawprint.fill",           ["walk", "dog", "pet", "cat",
                                     "산책", "강아지", "반려", "고양이",
                                     "散歩", "犬", "ペット", "猫"]),
        ("drop.fill",               ["water", "drink", "hydrat",
                                     "물", "수분", "음료",
                                     "水", "飲み物", "水分"]),
    ]

    public static func resolveIcon(for taskName: String, category: String?, urgency: Urgency = .strong) -> String {
        let name = taskName.lowercased()
        for rule in iconRules {
            if rule.keywords.contains(where: { name.contains($0) }) {
                return rule.icon
            }
        }
        
        if category == "Appointment" {
            // 약한 알림일 경우 달력 아이콘 제외 (사용자 요청)
            return urgency == .strong ? "calendar" : "clock"
        }
        return "circle.fill"
    }
}
