import Foundation
import UserNotifications

// MARK: - NotificationManager
/// 싱글톤 로컬 알림 관리자.
/// urgency(강/약)에 따라 두 백엔드로 라우팅합니다:
/// - strong × Pro × AlarmKit 허용 → 시스템 알람 (SystemAlarmScheduler — 앱이 꺼져 있어도 풀스크린)
/// - strong × 그 외              → time-sensitive 알림 + 링톤 + (일회성) +5/+10분 팔로업 + 스누즈 액션
/// - weak                        → 일반 배너 + "완료" 액션. 오버레이/링톤 없음
final class NotificationManager {

    // MARK: - Singleton
    static let shared = NotificationManager()
    private init() {}

    private let center = UNUserNotificationCenter.current()

    /// 취소된 태스크 id 레지스트리.
    /// strong×Pro 등록은 async(권한 확인 await 포함)라서, await 중에 태스크가 삭제되면
    /// 취소가 먼저 실행되고 등록이 나중에 완료되어 고아 알람이 부활하는 경합이 있다.
    /// 등록 완료 직전에 이 집합을 확인해 삭제된 태스크의 등록을 무산시킨다. (메인 스레드 전용)
    private var cancelledIds = Set<UUID>()

    // MARK: - Identifiers
    static let strongCategoryID = "STRONG_ALARM"
    static let weakCategoryID   = "WEAK_REMINDER"
    static let doneActionID     = "DONE_ACTION"
    static let snoozeActionID   = "SNOOZE_ACTION"

    /// 본체 외에 함께 정리해야 하는 파생 알림 id (팔로업 2개 + 스누즈)
    static func followUpIdentifiers(for id: String) -> [String] {
        ["\(id)-f1", "\(id)-f2", "\(id)-snooze"]
    }

    /// 일회성 strong의 재알림 체인 오프셋 (기준 시각 + 초)
    private static let followUpOffsets: [(suffix: String, seconds: TimeInterval)] = [
        ("-f1", 300),   // +5분
        ("-f2", 600),   // +10분
    ]

    /// 스누즈("5분 뒤 다시") 간격 (초)
    static let snoozeInterval: TimeInterval = 300

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

    /// D13/D14: Pro 여부 — SubscriptionManager가 App Group에 기록한 플래그
    private var isPremiumUser: Bool {
        UserDefaults(suiteName: appGroupID)?.bool(forKey: SubscriptionManager.premiumFlagKey) ?? false
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

        // 강한 알림: 완료 + 5분 뒤 다시 / 약한 알림: 완료
        // (액션 타이틀은 등록 시점 언어로 고정 — 알려진 제한)
        let doneAction = UNNotificationAction(
            identifier: Self.doneActionID,
            title: L.alarm.completeAction,
            options: []
        )
        let snoozeAction = UNNotificationAction(
            identifier: Self.snoozeActionID,
            title: L.alarm.snoozeAction,
            options: []
        )
        let strongCategory = UNNotificationCategory(
            identifier: Self.strongCategoryID,
            actions: [doneAction, snoozeAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        let weakCategory = UNNotificationCategory(
            identifier: Self.weakCategoryID,
            actions: [doneAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([strongCategory, weakCategory])

        // 포그라운드 알림 수신 + 액션 처리를 위한 Delegate 설정
        center.delegate = AlarmCoordinator.shared
    }

    // MARK: - Schedule (백엔드 라우터)
    /// AppTask를 받아 urgency·요금제·권한에 따라 AlarmKit 또는 UN에 등록합니다.
    /// 기존 알림이 있으면 덮어씁니다(동일 id 사용).
    func scheduleNotification(for task: AppTask) {
        cancelledIds.remove(task.id)   // 재등록이므로 이전 취소 기록 해제

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

        // ── strong × Pro → AlarmKit 시도 (최초 저장 시 권한 요청, 거부 시 UN 폴백) ──
        if task.urgency == .strong && isPremiumUser {
            let spec = makeSpec(
                for: task,
                fireDate: fireDate,
                alarmKit: alarmKitSchedule(for: task, fireDate: fireDate, lead: leadMinutes)
            )
            Task { @MainActor in
                if await SystemAlarmScheduler.shared.ensureAuthorized() {
                    guard !self.cancelledIds.contains(spec.id) else { return }  // await 중 삭제됨
                    self.removeAllUserNotifications(for: spec.id.uuidString)  // UN 흔적 제거 (백엔드 이관)
                    await SystemAlarmScheduler.shared.schedule(spec)
                } else {
                    SystemAlarmScheduler.shared.cancel(id: spec.id)
                    self.scheduleUserNotification(spec)
                }
            }
            return
        }

        // ── 그 외 전부 UN 경로 (백엔드 전환 대비 AlarmKit 흔적 제거) ──
        SystemAlarmScheduler.shared.cancel(id: task.id)
        scheduleUserNotification(makeSpec(for: task, fireDate: fireDate, alarmKit: nil))
    }

    // MARK: - UN 등록
    /// UN 알림 본체 + (일회성 strong) 팔로업 체인을 등록합니다.
    /// AlarmKit schedule 실패 시의 폴백 진입점이기도 합니다.
    func scheduleUserNotification(_ spec: AlarmSpec) {
        guard !cancelledIds.contains(spec.id) else { return }  // AlarmKit 폴백 도중 삭제됨
        let (components, repeats) = triggerComponents(for: spec)
        // 반복 알림은 기준시각이 과거여도 다음 발생에 매칭되므로 통과 (일회성만 미래 요구)
        guard repeats || spec.fireDate > Date() else { return }

        let content = UNMutableNotificationContent()
        let isRoutine = spec.category == "Routine"
        content.title = isRoutine ? L.settings.routineNotifTitle : L.settings.appointmentNotifTitle
        content.body  = "「\(spec.title)」"
        content.userInfo = [
            "taskId":   spec.id.uuidString,
            "taskName": spec.title,
            "urgency":  spec.urgency.rawValue,
        ]

        if spec.urgency == .strong {
            // 알람 의미론: 사운드 설정과 무관하게 링톤 + 집중 모드 관통(time-sensitive)
            content.subtitle = L.alarm.notifSubtitleStrong
            content.interruptionLevel = .timeSensitive
            content.sound = .defaultRingtone
            content.categoryIdentifier = Self.strongCategoryID
        } else {
            content.subtitle = L.alarm.notifSubtitleWeak
            content.interruptionLevel = .active
            content.sound = soundEnabled ? .default : nil
            content.categoryIdentifier = Self.weakCategoryID
        }

        // 기존 알림(본체+파생) 제거 후 새로 등록
        removeAllUserNotifications(for: spec.id.uuidString)

        let request = UNNotificationRequest(
            identifier: spec.id.uuidString,
            content:    content,
            trigger:    UNCalendarNotificationTrigger(dateMatching: components, repeats: repeats)
        )
        center.add(request) { error in
            if let error {
                print("❌ 알림 등록 실패 [\(spec.title)]: \(error.localizedDescription)")
            } else {
                let urgencyLabel = spec.urgency == .strong ? "🔴강함" : "🔵약함"
                print("🔔 알림 등록 완료 [\(urgencyLabel)]: \(spec.title) @ \(spec.fireDate)")
            }
        }

        // 일회성 strong → +5/+10분 재알림 체인 (한 번 놓쳐도 끝나지 않게)
        // 반복 태스크에는 매일 반복되는 잔소리가 되므로 걸지 않음
        if spec.urgency == .strong && !repeats {
            for follow in Self.followUpOffsets {
                let followDate = spec.fireDate.addingTimeInterval(follow.seconds)
                guard followDate > Date() else { continue }
                guard let followContent = content.mutableCopy() as? UNMutableNotificationContent else { continue }
                followContent.subtitle = L.alarm.notifSubtitleFollowUp
                let trigger = UNCalendarNotificationTrigger(
                    dateMatching: Calendar.current.dateComponents(
                        [.year, .month, .day, .hour, .minute], from: followDate),
                    repeats: false
                )
                center.add(UNNotificationRequest(
                    identifier: spec.id.uuidString + follow.suffix,
                    content: followContent,
                    trigger: trigger
                ))
            }
        }
    }

    // MARK: - Snooze ("5분 뒤 다시")
    /// 울린 알림의 콘텐츠를 복사해 +5분 뒤 일회성으로 재등록합니다.
    func scheduleSnooze(from request: UNNotificationRequest) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent,
              let taskId = content.userInfo["taskId"] as? String else { return }
        content.subtitle = L.alarm.notifSubtitleFollowUp

        let snoozeID = "\(taskId)-snooze"
        center.removePendingNotificationRequests(withIdentifiers: [snoozeID])
        center.add(UNNotificationRequest(
            identifier: snoozeID,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: Self.snoozeInterval, repeats: false)
        ))
        print("😴 스누즈 등록: \(snoozeID) (+\(Int(Self.snoozeInterval))초)")
    }

    // MARK: - Cancel
    /// 본체 + 파생(팔로업/스누즈) + AlarmKit까지 전부 취소 (삭제/일회성 완료 시)
    func cancelNotification(for task: AppTask) {
        cancelledIds.insert(task.id)   // 진행 중인 async 등록이 있으면 무산시킴
        removeAllUserNotifications(for: task.id.uuidString)
        SystemAlarmScheduler.shared.cancel(id: task.id)
    }

    // MARK: - Orphan Sweep
    /// 존재하지 않는 태스크의 pending 알림을 회수합니다 (본체 + 파생 suffix 전부).
    /// 등록-삭제 경합이나 과거 버전이 남긴 알림이 있어도 포그라운드마다 자가치유됩니다.
    func removeOrphanedNotifications(validIds: Set<UUID>) {
        center.getPendingNotificationRequests { requests in
            let orphaned = requests.filter { request in
                guard let taskId = Self.baseTaskId(fromIdentifier: request.identifier)
                        ?? (request.content.userInfo["taskId"] as? String).flatMap(UUID.init)
                else { return false }   // 이 앱 체계 밖의 알림은 건드리지 않음
                return !validIds.contains(taskId)
            }.map(\.identifier)
            guard !orphaned.isEmpty else { return }
            self.center.removePendingNotificationRequests(withIdentifiers: orphaned)
            print("🧹 고아 알림 \(orphaned.count)건 회수")
        }
    }

    /// "uuid" / "uuid-f1" / "uuid-f2" / "uuid-snooze" → uuid
    private static func baseTaskId(fromIdentifier identifier: String) -> UUID? {
        for follow in followUpIdentifiers(for: "") where identifier.hasSuffix(follow) {
            return UUID(uuidString: String(identifier.dropLast(follow.count)))
        }
        return UUID(uuidString: identifier)
    }

    /// 본체(반복 스케줄)는 유지하고 파생 알림만 제거 — 반복 태스크의 오늘 완료 시 사용
    func cancelFollowUps(taskIdString: String) {
        center.removePendingNotificationRequests(
            withIdentifiers: Self.followUpIdentifiers(for: taskIdString))
    }

    private func removeAllUserNotifications(for idString: String) {
        center.removePendingNotificationRequests(
            withIdentifiers: [idString] + Self.followUpIdentifiers(for: idString))
    }

    // MARK: - Spec Builders

    private func makeSpec(for task: AppTask, fireDate: Date, alarmKit: AlarmKitScheduleKind?) -> AlarmSpec {
        AlarmSpec(
            id: task.id,
            title: task.task,
            category: task.category,
            recurrenceRule: task.recurrenceRule,
            hasDate: task.date != nil,
            fireDate: fireDate,
            urgency: task.urgency,
            alarmKitSchedule: alarmKit
        )
    }

    /// UN 트리거 규칙 (기존 로직 유지):
    /// weekly/biweekly → 요일+시분 반복(biweekly는 iOS 제약으로 주간 등록 — 알려진 제한)
    /// monthly → 일+시분 / yearly → 월일+시분 / date 없음 → 매일 / 그 외 → 일회성
    private func triggerComponents(for spec: AlarmSpec) -> (DateComponents, Bool) {
        let cal = Calendar.current
        if let rule = spec.recurrenceRule {
            switch rule {
            case "weekly", "biweekly":
                return (cal.dateComponents([.weekday, .hour, .minute], from: spec.fireDate), true)
            case "monthly":
                return (cal.dateComponents([.day, .hour, .minute], from: spec.fireDate), true)
            case "yearly":
                return (cal.dateComponents([.month, .day, .hour, .minute], from: spec.fireDate), true)
            default:
                return (cal.dateComponents([.year, .month, .day, .hour, .minute], from: spec.fireDate), false)
            }
        } else if !spec.hasDate {
            // date가 없으면 매일 반복하는 루틴
            return (cal.dateComponents([.hour, .minute], from: spec.fireDate), true)
        }
        return (cal.dateComponents([.year, .month, .day, .hour, .minute], from: spec.fireDate), false)
    }

    /// AlarmKit 스케줄 매핑:
    /// 매일 루틴 → 7요일 relative / weekly → 해당 요일 relative
    /// biweekly·monthly·yearly → occursOn 스캔으로 다음 발생일 fixed (완료/포그라운드 시 재무장)
    /// 일회성 → fixed
    private func alarmKitSchedule(for task: AppTask, fireDate: Date, lead: Int) -> AlarmKitScheduleKind? {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: fireDate)
        let minute = cal.component(.minute, from: fireDate)

        if let rule = task.recurrenceRule {
            switch rule {
            case "weekly":
                return .weekly(
                    weekday: Self.localeWeekday(cal.component(.weekday, from: fireDate)),
                    hour: hour, minute: minute
                )
            case "biweekly", "monthly", "yearly":
                guard let next = nextFixedOccurrence(for: task, lead: lead) else { return nil }
                return .fixed(next)
            default:
                return fireDate > Date() ? .fixed(fireDate) : nil
            }
        } else if task.date == nil {
            return .daily(hour: hour, minute: minute)
        }
        return fireDate > Date() ? .fixed(fireDate) : nil
    }

    /// biweekly/monthly/yearly의 다음 발생 시각 (미래 최초 1건, 최대 366일 스캔)
    private func nextFixedOccurrence(for task: AppTask, lead: Int) -> Date? {
        guard let time = task.time else { return nil }
        let cal = Calendar.current
        for offset in 0...366 {
            guard let day = cal.date(byAdding: .day, value: offset, to: Date()) else { continue }
            guard task.occursOn(day) else { continue }
            guard let fire = parseTime(time, on: day)?
                .addingTimeInterval(-Double(lead * 60)) else { continue }
            if fire > Date() { return fire }
        }
        return nil
    }

    /// Calendar weekday(1=일 … 7=토) → Locale.Weekday
    private static func localeWeekday(_ calendarWeekday: Int) -> Locale.Weekday {
        switch calendarWeekday {
        case 1: return .sunday
        case 2: return .monday
        case 3: return .tuesday
        case 4: return .wednesday
        case 5: return .thursday
        case 6: return .friday
        default: return .saturday
        }
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
