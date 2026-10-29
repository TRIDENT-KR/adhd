import Foundation
import CryptoKit

// MARK: - App Group Identifier
/// 메인 앱과 위젯 간 데이터 공유를 위한 App Group ID
nonisolated let appGroupID = "group.trident-KR.ADHD"

/// 위젯이 현재 로그인한 Mora 계정의 데이터만 읽도록 하는 App Group 범위입니다.
enum WidgetAccountScope {
    static let activeScopeKey = "activeWidgetAccountScope"
    static let premiumScopeKey = "premiumWidgetAccountScope"

    /// 로그인하지 않은 게스트의 범위. AccountPreferences.scope(for: LocalGuestIdentity.storageID)와 같은 값이며,
    /// 위젯이 '로그인이 필요해요'와 '앱을 한 번 열어 주세요'를 구분할 때 씁니다.
    static let guest: String = SHA256.hash(data: Data("00000000-0000-0000-0000-000000000000".utf8))
        .map { String(format: "%02x", $0) }
        .joined()

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

// MARK: - 다음 날 목록
/// 앱을 다음 날 아침까지 열지 않아도 자정 이후 위젯이 그날 목록을 보여 주도록, 앱이 미리 담아 두는 하루치 목록입니다.
struct WidgetDayTasks: Codable {
    let routines: [WidgetTaskSnapshot]
    let appointments: [WidgetTaskSnapshot]
}

// MARK: - Widget Data Payload
/// 위젯에 전달하는 전체 데이터 패킷
struct WidgetDataPayload: Codable {
    let accountScope: String
    let routines: [WidgetTaskSnapshot]
    let appointments: [WidgetTaskSnapshot]
    let updatedAt: Date
    /// updatedAt 다음 날의 목록. 이전 버전 앱이 남긴 기록에는 없습니다.
    var nextDay: WidgetDayTasks? = nil

    /// 오늘 보여 줄 할 일이 하나라도 있는지 (모두 끝냄 / 아예 없음 구분)
    var hasTasks: Bool {
        !routines.isEmpty || !appointments.isEmpty
    }

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
    /// 바로 다음 날이면 앱이 미리 담아 둔 그날 목록(오늘 일정, 날짜를 정한 루틴까지)을 씁니다.
    /// 그보다 오래됐으면 루틴은 미완료로 되돌리고, 날짜가 있던 일정은 오늘 것이 아니므로 숨깁니다.
    func normalized(for now: Date, calendar: Calendar = .current) -> WidgetDataPayload {
        guard !calendar.isDate(updatedAt, inSameDayAs: now) else { return self }
        if let nextDay,
           let followingDay = calendar.date(byAdding: .day, value: 1, to: updatedAt),
           calendar.isDate(followingDay, inSameDayAs: now) {
            // 그날 0시를 기록 시각으로 두어, 다시 고쳐도 같은 결과가 나오게 합니다.
            return WidgetDataPayload(
                accountScope: accountScope,
                routines: nextDay.routines,
                appointments: nextDay.appointments,
                updatedAt: calendar.startOfDay(for: now)
            )
        }
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
        guard let midnight = nextMidnight(after: now, calendar: calendar) else {
            return quarterHour
        }
        return min(quarterHour, midnight)
    }

    /// 다음 자정. 시스템이 갱신을 미뤄도 자정에 날짜가 바뀌도록 타임라인에 그 시각 항목을 하나 더 넣을 때 씁니다.
    static func nextMidnight(after now: Date, calendar: Calendar = .current) -> Date? {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
    }
}
