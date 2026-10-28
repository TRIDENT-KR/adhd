import Foundation

// MARK: - App Group Identifier
/// 메인 앱과 위젯 간 데이터 공유를 위한 App Group ID
nonisolated let appGroupID = "group.trident-KR.ADHD"

/// 위젯이 현재 로그인한 Mora 계정의 데이터만 읽도록 하는 App Group 범위입니다.
enum WidgetAccountScope {
    static let activeScopeKey = "activeWidgetAccountScope"
    static let premiumScopeKey = "premiumWidgetAccountScope"

    static var active: String? {
        UserDefaults(suiteName: appGroupID)?.string(forKey: activeScopeKey)
    }

    static func activate(_ scope: String) {
        UserDefaults(suiteName: appGroupID)?.set(scope, forKey: activeScopeKey)
    }

    static func deactivate() {
        let defaults = UserDefaults(suiteName: appGroupID)
        defaults?.removeObject(forKey: activeScopeKey)
        defaults?.removeObject(forKey: premiumScopeKey)
    }
}

// MARK: - Widget Task Snapshot (Lightweight DTO)
/// 위젯에 표시할 태스크의 경량 스냅샷 (SwiftData 의존성 없음)
struct WidgetTaskSnapshot: Codable, Identifiable {
    let id: UUID
    let task: String
    let time: String?
    let category: String       // "Routine" | "Appointment"
    let isCompleted: Bool
    let recurrenceLabel: String?

    /// 위젯에 보여줄 시간: 앱 언어(App Group에 복제된 값) 형식으로 "오후 3:00", "3:00 PM", "15:00".
    /// 읽을 수 없는 값은 원문 그대로입니다.
    var displayTime: String? {
        guard let time, !time.isEmpty else { return nil }
        let clock = sortableTime.split(separator: ":").compactMap { Int($0) }
        guard clock.count == 2,
              let date = Calendar(identifier: .gregorian).date(
                from: DateComponents(year: 2000, month: 1, day: 1, hour: clock[0], minute: clock[1])
              ) else { return time }
        let language = UserDefaults(suiteName: appGroupID)?.string(forKey: "appLanguage") ?? "en"
        let localeID = ["ko": "ko-KR", "ja": "ja-JP"][language] ?? "en-US"
        return date.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: localeID))
        )
    }

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
    let accountScope: String
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

// MARK: - 날짜가 지난 위젯 데이터
extension WidgetDataPayload {
    /// 앱이 오늘 아직 열리지 않아 어제 기록이 남아 있으면 오늘 기준으로 고칩니다.
    /// 루틴은 미완료로 되돌리고, 날짜가 있던 일정은 오늘 것이 아니므로 숨깁니다.
    func normalized(for now: Date, calendar: Calendar = .current) -> WidgetDataPayload {
        guard !calendar.isDate(updatedAt, inSameDayAs: now) else { return self }
        return WidgetDataPayload(
            accountScope: accountScope,
            routines: routines.map {
                WidgetTaskSnapshot(
                    id: $0.id,
                    task: $0.task,
                    time: $0.time,
                    category: $0.category,
                    isCompleted: false,
                    recurrenceLabel: $0.recurrenceLabel
                )
            },
            appointments: [],
            updatedAt: updatedAt
        )
    }

    /// 다음 위젯 갱신 시각: 15분 뒤와 자정 중 빠른 쪽. 자정이 지나도 어제 상태가 남지 않게 합니다.
    static func nextRefreshDate(after now: Date, calendar: Calendar = .current) -> Date {
        let quarterHour = now.addingTimeInterval(15 * 60)
        guard let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else {
            return quarterHour
        }
        return min(quarterHour, midnight)
    }
}
