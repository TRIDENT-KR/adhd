import Foundation
import UserNotifications

// MARK: - NotificationManager
/// 싱글톤으로 운영되는 로컬 알림 관리자.
/// 알림 권한 요청과 UNCalendarNotificationTrigger 기반 스케줄링을 담당합니다.
final class NotificationManager {

    // MARK: - Singleton
    static let shared = NotificationManager()
    private init() {}

    private let center = UNUserNotificationCenter.current()

    // MARK: - Cached Formatters
    private static let timeFormatters: [DateFormatter] = {
        let formats = ["hh:mm a", "h:mm a", "HH:mm"]
        return formats.map { format in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            return f
        }
    }()

    // MARK: - Settings Keys
    static let routineRemindersKey    = "routineRemindersEnabled"
    static let appointmentRemindersKey = "appointmentRemindersEnabled"
    static let remindBeforeKey         = "remindBeforeMinutes"
    static let soundEnabledKey         = "notificationSoundEnabled"

    var routineRemindersEnabled: Bool {
        // 기본값 true (UserDefaults에 키가 없으면 true 반환)
        !UserDefaults.standard.bool(forKey: "routineRemindersDisabled")
    }
    var appointmentRemindersEnabled: Bool {
        !UserDefaults.standard.bool(forKey: "appointmentRemindersDisabled")
    }
    var remindBeforeMinutes: Int {
        let val = UserDefaults.standard.integer(forKey: Self.remindBeforeKey)
        return val == 0 ? 0 : val // 0 = 정시
    }
    var soundEnabled: Bool {
        !UserDefaults.standard.bool(forKey: "notificationSoundDisabled")
    }

    // MARK: - Permission Request
    /// App 실행 시 onAppear에서 한 번 호출합니다.
    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                print("❌ 알림 권한 요청 실패: \(error.localizedDescription)")
                return
            }
            print(granted ? "✅ 알림 권한 허용됨" : "🔕 알림 권한 거부됨")
        }
    }

    // MARK: - Schedule Notification
    /// AppTask를 받아 time 문자열을 파싱하고 정확한 시간에 알림을 등록합니다.
    /// 기존 알림이 있으면 덮어씁니다(동일 id 사용).
    func scheduleNotification(for task: AppTask) {
        // 카테고리별 토글 확인
        if task.category == "Routine" && !routineRemindersEnabled { return }
        if task.category == "Appointment" && !appointmentRemindersEnabled { return }

        guard let time = task.time, !time.isEmpty else { return }
        guard var fireDate = parseTime(time, on: task.date) else {
            print("⚠️ 시간 파싱 실패: \(time)")
            return
        }

        // Remind Before: 사전 알림 시간 적용
        let leadMinutes = remindBeforeMinutes
        if leadMinutes > 0 {
            fireDate = fireDate.addingTimeInterval(-Double(leadMinutes * 60))
        }

        // 이미 지난 시간이면 등록 생략
        guard fireDate > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title  = task.category == "Routine" ? L.settings.routineNotifTitle : L.settings.appointmentNotifTitle
        content.body   = task.task
        content.sound  = soundEnabled ? .default : nil

        var components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: fireDate
        )
        // date가 없으면 매일 반복하는 루틴처럼 동작
        if task.date == nil {
            components = Calendar.current.dateComponents([.hour, .minute], from: fireDate)
        }

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: components,
            repeats: task.date == nil   // date 없는 루틴은 매일 반복
        )

        let request = UNNotificationRequest(
            identifier: task.id.uuidString,
            content:    content,
            trigger:    trigger
        )

        // 기존 알림 제거 후 새로 등록
        center.removePendingNotificationRequests(withIdentifiers: [task.id.uuidString])
        center.add(request) { error in
            if let error {
                print("❌ 알림 등록 실패 [\(task.task)]: \(error.localizedDescription)")
            } else {
                print("🔔 알림 등록 완료: \(task.task) @ \(fireDate)")
            }
        }
    }

    // MARK: - Cancel Notification
    func cancelNotification(for task: AppTask) {
        center.removePendingNotificationRequests(withIdentifiers: [task.id.uuidString])
    }

    // MARK: - Private: Time Parsing
    /// "07:00 AM", "02:00 PM", "14:00" 등 다양한 포맷을 허용합니다.
    private func parseTime(_ timeString: String, on date: Date?) -> Date? {
        let base = date ?? Date()
        let trimmed = timeString.trimmingCharacters(in: .whitespaces)

        for formatter in Self.timeFormatters {
            if let parsed = formatter.date(from: trimmed) {
                let parsedComponents = Calendar.current.dateComponents([.hour, .minute], from: parsed)
                var baseComponents   = Calendar.current.dateComponents([.year, .month, .day], from: base)
                baseComponents.hour   = parsedComponents.hour
                baseComponents.minute = parsedComponents.minute
                baseComponents.second = 0
                return Calendar.current.date(from: baseComponents)
            }
        }
        return nil
    }
}
