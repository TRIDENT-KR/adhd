import Foundation
import UserNotifications
import CryptoKit

enum AccountPreferenceKey: String {
    case routineRemindersDisabled
    case appointmentRemindersDisabled
    case remindBeforeMinutes
    case notificationSoundDisabled
    case confirmBeforeSave
    case aiDataConsentVersion
    case lastDailyResetDate = "lastResetDate"
    /// 로그인 직후 '기기 일정 가져오기'를 이미 물어봤는지 (계정마다 한 번)
    case guestImportOffered
}

/// 계정별 설정을 raw Mora UUID가 노출되지 않는 UserDefaults namespace에 저장합니다.
enum AccountPreferences {
    private static let activeScopeKey = "mora.active-account-preference-scope.v1"
    private static let generationKey = "mora.active-account-generation.v1"

    static func sessionGeneration(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: generationKey)
    }

    static var hasActiveAccount: Bool {
        activeScope != nil
    }

    static func activate(for userID: UUID, defaults: UserDefaults = .standard) {
        if defaults.string(forKey: activeScopeKey) != scope(for: userID)
            || sessionGeneration(defaults: defaults) == nil {
            defaults.set(UUID().uuidString, forKey: generationKey)
        }
        defaults.set(scope(for: userID), forKey: activeScopeKey)
    }

    static func deactivate(defaults: UserDefaults = .standard) {
        defaults.set(UUID().uuidString, forKey: generationKey)
        defaults.removeObject(forKey: activeScopeKey)
    }

    static func bool(
        _ key: AccountPreferenceKey,
        default defaultValue: Bool,
        for userID: UUID? = nil,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let namespaced = namespacedKey(key, for: userID, defaults: defaults) else {
            return defaultValue
        }
        guard defaults.object(forKey: namespaced) != nil else { return defaultValue }
        return defaults.bool(forKey: namespaced)
    }

    static func integer(
        _ key: AccountPreferenceKey,
        default defaultValue: Int,
        for userID: UUID? = nil,
        defaults: UserDefaults = .standard
    ) -> Int {
        guard let namespaced = namespacedKey(key, for: userID, defaults: defaults),
              defaults.object(forKey: namespaced) != nil else { return defaultValue }
        return defaults.integer(forKey: namespaced)
    }

    static func set(
        _ value: Bool,
        for key: AccountPreferenceKey,
        userID: UUID? = nil,
        defaults: UserDefaults = .standard
    ) {
        guard let namespaced = namespacedKey(key, for: userID, defaults: defaults) else { return }
        defaults.set(value, forKey: namespaced)
    }

    static func removeAll(
        for userID: UUID,
        defaults: UserDefaults = .standard
    ) {
        let accountScope = scope(for: userID)
        for key in [
            AccountPreferenceKey.routineRemindersDisabled,
            .appointmentRemindersDisabled,
            .remindBeforeMinutes,
            .notificationSoundDisabled,
            .confirmBeforeSave,
            .aiDataConsentVersion,
            .lastDailyResetDate,
            .guestImportOffered,
        ] {
            defaults.removeObject(
                forKey: "mora.account.\(accountScope).\(key.rawValue).v1"
            )
        }
        defaults.removeObject(forKey: "mora.account.\(accountScope).\(lastResetDateBase).v1")
    }

    /// 계정별 일일 초기화 기준일 키의 바탕 이름입니다(TaskManager가 사용).
    static let lastResetDateBase = "lastResetDate"

    /// 활성 계정 범위로 묶인 키입니다. 활성 계정이 없으면(게스트) nil입니다.
    static func scopedKey(_ base: String, defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: activeScopeKey).map { "mora.account.\($0).\(base).v1" }
    }

    static func set(
        _ value: Int,
        for key: AccountPreferenceKey,
        userID: UUID? = nil,
        defaults: UserDefaults = .standard
    ) {
        guard let namespaced = namespacedKey(key, for: userID, defaults: defaults) else { return }
        defaults.set(value, forKey: namespaced)
    }

    nonisolated static func scope(for userID: UUID) -> String {
        SHA256.hash(data: Data(userID.uuidString.lowercased().utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static var activeScope: String? {
        UserDefaults.standard.string(forKey: activeScopeKey)
    }

    static func date(_ key: AccountPreferenceKey, defaults: UserDefaults = .standard) -> Date? {
        guard let namespaced = namespacedKey(key, for: nil, defaults: defaults) else { return nil }
        return defaults.object(forKey: namespaced) as? Date
    }

    static func set(_ value: Date, for key: AccountPreferenceKey, defaults: UserDefaults = .standard) {
        guard let namespaced = namespacedKey(key, for: nil, defaults: defaults) else { return }
        defaults.set(value, forKey: namespaced)
    }

    private static func namespacedKey(
        _ key: AccountPreferenceKey,
        for userID: UUID?,
        defaults: UserDefaults
    ) -> String? {
        let accountScope = userID.map(scope(for:))
            ?? defaults.string(forKey: activeScopeKey)
        guard let accountScope else { return nil }
        return "mora.account.\(accountScope).\(key.rawValue).v1"
    }
}

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
    private var sessionGeneration = 0

    /// Invalidate registrations suspended inside the system scheduling API.
    func invalidatePendingRegistrations() {
        sessionGeneration += 1
    }

    // MARK: - Identifiers
    static let strongCategoryID = "STRONG_ALARM"
    static let weakCategoryID   = "WEAK_REMINDER"
    static let doneActionID     = "DONE_ACTION"
    static let snoozeActionID   = "SNOOZE_ACTION"

    /// 본체 외에 함께 정리해야 하는 파생 알림 id (팔로업 2개 + 스누즈)
    static func followUpIdentifiers(for id: String) -> [String] {
        ["\(id)-f1", "\(id)-f2", "\(id)-snooze"]
    }

    /// 건너뛸 회차가 있는 반복의 알림 id 슬롯 7개.
    /// 매일 루틴은 요일별 반복(1=일 … 7=토), 매주 반복은 다가오는 회차를 차례로 담습니다.
    /// '완료' 액션의 팔로업 정리(cancelFollowUps)에는 포함하지 않습니다 — 지우면 다른 날 알림까지 사라집니다.
    static func skipDayIdentifiers(for id: String) -> [String] {
        (1...upcomingSlotCount).map { "\(id)-d\($0)" }
    }

    /// 매주 반복에서 직접 예약하는 다가오는 회차 수 (id 슬롯 수와 같음)
    static let upcomingSlotCount = 7

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
        AccountPreferences.hasActiveAccount
            && !AccountPreferences.bool(.routineRemindersDisabled, default: false)
    }
    var appointmentRemindersEnabled: Bool {
        AccountPreferences.hasActiveAccount
            && !AccountPreferences.bool(.appointmentRemindersDisabled, default: false)
    }
    var remindBeforeMinutes: Int {
        AccountPreferences.integer(.remindBeforeMinutes, default: 0)
    }
    var soundEnabled: Bool {
        AccountPreferences.hasActiveAccount
            && !AccountPreferences.bool(.notificationSoundDisabled, default: false)
    }

    /// D13/D14: Pro 여부 — SubscriptionManager가 App Group에 기록한 플래그
    private var isPremiumUser: Bool {
        UserDefaults(suiteName: appGroupID)?.bool(forKey: SubscriptionManager.premiumFlagKey) ?? false
    }

    // MARK: - Launch Wiring
    /// 앱 실행이 끝나기 전에(AppDelegate) 호출합니다.
    /// 앱이 꺼진 상태에서 잠금화면 '완료'·'5분 뒤 다시'로 깨어나면 화면이 뜨지 않으므로,
    /// delegate를 화면 흐름에서 연결하면 그 응답을 받을 곳이 없습니다.
    func configureNotificationHandling() {
        registerCategories()
        center.delegate = AlarmCoordinator.shared
    }

    /// 사용자가 iPhone 설정에서 알림을 거부했는지 확인합니다. 아직 묻지 않았으면 false입니다.
    func isAuthorizationDenied() async -> Bool {
        await center.notificationSettings().authorizationStatus == .denied
    }

    // MARK: - Permission Request
    /// App 실행 시 onAppear에서 한 번 호출합니다.
    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if error != nil {
                print("notification_authorization_failed")
                return
            }
            print(granted ? "✅ 알림 권한 허용됨" : "🔕 알림 권한 거부됨")
        }
        // 실행 이후 바뀐 앱 언어로 액션 이름을 다시 등록합니다.
        registerCategories()
    }

    /// 앱 언어를 바꾸면 알림의 '완료'·'5분 뒤 다시' 버튼 이름도 새 언어로 다시 등록합니다.
    func refreshCategoriesForLanguageChange() {
        registerCategories()
    }

    private func registerCategories() {
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
    }

    // MARK: - Schedule (백엔드 라우터)
    /// AppTask를 받아 urgency·요금제·권한에 따라 AlarmKit 또는 UN에 등록합니다.
    /// 기존 알림이 있으면 덮어씁니다(동일 id 사용).
    func scheduleNotification(for task: AppTask) {
        cancelledIds.remove(task.id)   // 재등록이므로 이전 취소 기록 해제

        // 끝난 일회성 일정은 수정·되돌리기를 거쳐도 다시 울리지 않게 합니다.
        if task.isCompleted && !task.hasRepeatingSchedule {
            cancelNotification(for: task)
            return
        }

        // 카테고리별 토글 확인
        if task.category == "Routine" && !routineRemindersEnabled { return }
        if task.category == "Appointment" && !appointmentRemindersEnabled { return }

        // 시간을 지웠거나 읽을 수 없으면 예전 시각의 알림이 남지 않게 지웁니다.
        guard let time = task.time, !time.isEmpty else {
            cancelNotification(for: task)
            return
        }
        let calendar = Calendar.current
        guard let clock = parseTimeComponents(time, calendar: calendar) else {
            print("notification_time_parse_failed")
            cancelNotification(for: task)
            return
        }

        let now = Date()
        let leadMinutes = remindBeforeMinutes
        // 오늘 회차를 이미 완료한 반복 태스크는 오늘 남은 알림을 울리지 않습니다.
        // '이번만 건너뛰기'로 뺀 날도 같은 방식으로 뺍니다.
        let completedToday = task.isCompleted && task.hasRepeatingSchedule
        let isExcluded: (Date) -> Bool = { day in
            (completedToday && calendar.isDate(day, inSameDayAs: now)) || task.isSkipped(on: day)
        }
        let fireDate: Date
        if let rule = task.recurrenceRule,
           RecurrenceEngine.requiresOneShotNotification(rule) {
            guard let anchor = task.date,
                  let next = Self.nextIncludedFireDate(
                    after: now, anchor: anchor, rule: rule,
                    hour: clock.hour, minute: clock.minute,
                    leadMinutes: leadMinutes, calendar: calendar,
                    isExcluded: isExcluded
                  ) else {
                cancelNotification(for: task)
                return
            }
            fireDate = next
        } else {
            guard let occurrence = RecurrenceEngine.wallClockDate(
                on: task.date ?? now,
                hour: clock.hour,
                minute: clock.minute,
                calendar: calendar
            ), let adjusted = calendar.date(
                byAdding: .minute,
                value: -leadMinutes,
                to: occurrence
            ) else { return }
            fireDate = adjusted
        }

        let skipPlan = Self.skipPlan(
            recurrenceRule: task.recurrenceRule, anchor: task.date,
            hour: clock.hour, minute: clock.minute,
            leadMinutes: leadMinutes, now: now, calendar: calendar,
            isExcluded: isExcluded
        )

        // ── strong × Pro → AlarmKit 시도 (최초 저장 시 권한 요청, 거부 시 UN 폴백) ──
        if task.urgency == .strong && isPremiumUser {
            let spec = makeSpec(
                for: task,
                fireDate: fireDate,
                alarmKit: alarmKitSchedule(for: task, fireDate: fireDate, skipPlan: skipPlan),
                skipPlan: skipPlan
            )
            let generation = sessionGeneration
            let accountScope = AccountPreferences.activeScope
            Task { @MainActor in
                let authorized = await SystemAlarmScheduler.shared.ensureAuthorized()
                guard self.sessionGeneration == generation,
                      AccountPreferences.activeScope == accountScope,
                      !self.cancelledIds.contains(spec.id) else { return }
                if authorized {
                    self.removeAllUserNotifications(for: spec.id.uuidString)  // UN 흔적 제거 (백엔드 이관)
                    await SystemAlarmScheduler.shared.schedule(spec) {
                        self.sessionGeneration == generation &&
                        AccountPreferences.activeScope == accountScope &&
                        !self.cancelledIds.contains(spec.id)
                    }
                } else {
                    SystemAlarmScheduler.shared.cancel(id: spec.id)
                    self.scheduleUserNotification(spec)
                }
            }
            return
        }

        // ── 그 외 전부 UN 경로 (백엔드 전환 대비 AlarmKit 흔적 제거) ──
        SystemAlarmScheduler.shared.cancel(id: task.id)
        scheduleUserNotification(makeSpec(for: task, fireDate: fireDate, alarmKit: nil, skipPlan: skipPlan))
    }

    /// 포그라운드마다 다시 계산해야 하는 예약인지:
    /// 한 회차씩만 거는 반복(격주·매월·매년), 건너뛴 회차 기록이 있는 반복, 시작 전인 매주 반복.
    /// 건너뛴 날이 지난 뒤에도 한 번은 다시 계산해야 빼 두었던 요일·회차가 평소 반복으로 돌아옵니다.
    static func needsForegroundRearm(_ task: AppTask, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        if RecurrenceEngine.requiresOneShotNotification(task.recurrenceRule) { return true }
        guard task.hasRepeatingSchedule else { return false }
        if !task.skippedDayKeys.isEmpty { return true }
        if task.recurrenceRule == "weekly", let anchor = task.date {
            return calendar.startOfDay(for: anchor) > calendar.startOfDay(for: now)
        }
        return false
    }

    /// 격주·매월·매년 반복에서 뺄 날을 건너뛴 다음 알림 시각입니다.
    static func nextIncludedFireDate(
        after now: Date,
        anchor: Date,
        rule: String,
        hour: Int,
        minute: Int,
        leadMinutes: Int,
        calendar: Calendar,
        isExcluded: (Date) -> Bool
    ) -> Date? {
        var searchStart = now
        // 건너뛴 날이 연달아 있어도 끝없이 돌지 않게 상한을 둡니다.
        for _ in 0..<12 {
            guard let fire = RecurrenceEngine.nextScheduledDate(
                after: searchStart, anchor: anchor, rule: rule,
                hour: hour, minute: minute, leadMinutes: leadMinutes, calendar: calendar
            ) else { return nil }
            // 알림 시각이 아니라 회차 날짜(리드 타임을 되돌린 날)로 판단합니다.
            let occurrenceDay = calendar.date(byAdding: .minute, value: leadMinutes, to: fire) ?? fire
            guard isExcluded(occurrenceDay) else { return fire }
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: occurrenceDay)) else { return nil }
            searchStart = max(nextDay, fire)
        }
        return nil
    }

    /// 매일·매주 반복에서 뺄 회차가 다가오거나(오늘 미리 완료, '이번만 건너뛰기') 매주 반복이 아직 시작 전이면
    /// 그 회차를 뺀 예약 형태를 고릅니다. nil이면 평소 반복 예약입니다.
    /// 뺄 날이 지나면 nil로 돌아가므로, 일일 초기화와 포그라운드 재무장이 원래 반복으로 되돌립니다.
    /// - Parameter isExcluded: 그날(현지 날짜) 회차를 울리지 않아야 하면 true
    static func skipPlan(
        recurrenceRule: String?,
        anchor: Date?,
        hour: Int,
        minute: Int,
        leadMinutes: Int,
        now: Date,
        calendar: Calendar,
        isExcluded: (Date) -> Bool
    ) -> SkipPlan? {
        let today = calendar.startOfDay(for: now)
        func fireDate(on day: Date) -> Date? {
            RecurrenceEngine.wallClockDate(on: day, hour: hour, minute: minute, calendar: calendar)
                .flatMap { calendar.date(byAdding: .minute, value: -leadMinutes, to: $0) }
        }

        switch (recurrenceRule, anchor) {
        case (nil, nil):
            // 다가오는 7회(요일마다 한 번) 중 뺄 회차가 있으면 그 요일만 빼고 매주 반복합니다.
            var excludedWeekdays = Set<Int>()
            var seen = 0
            for offset in 0..<8 where seen < 7 {   // 오늘 알림이 이미 지났으면 8일째까지 봐야 7회
                guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                      let fire = fireDate(on: day), fire > now else { continue }
                seen += 1
                if isExcluded(day) { excludedWeekdays.insert(calendar.component(.weekday, from: fire)) }
            }
            guard !excludedWeekdays.isEmpty else { return nil }
            return .otherWeekdays((1...7).filter { !excludedWeekdays.contains($0) })

        case ("weekly", let anchor?):
            // 반복 트리거는 시작일을 정할 수 없으므로, 시작 전이거나 뺄 회차가 있으면 회차를 직접 예약합니다.
            let notStarted = calendar.startOfDay(for: anchor) > today
            let searchStart = max(today, calendar.startOfDay(for: anchor))
            var dates: [Date] = []
            var excludedAny = false
            var seen = 0
            for offset in 0..<(7 * (upcomingSlotCount + 1)) where seen < upcomingSlotCount {
                guard let day = calendar.date(byAdding: .day, value: offset, to: searchStart),
                      RecurrenceEngine.occurs(on: day, anchor: anchor, rule: "weekly", calendar: calendar),
                      let fire = fireDate(on: day), fire > now else { continue }
                seen += 1
                if isExcluded(day) { excludedAny = true } else { dates.append(fire) }
            }
            guard notStarted || excludedAny else { return nil }
            return .upcoming(dates)

        default:
            return nil
        }
    }

    // MARK: - UN 등록
    /// UN 알림 본체 + (일회성 strong) 팔로업 체인을 등록합니다.
    /// AlarmKit schedule 실패 시의 폴백 진입점이기도 합니다.
    func scheduleUserNotification(_ spec: AlarmSpec) {
        guard !cancelledIds.contains(spec.id) else { return }  // AlarmKit 폴백 도중 삭제됨
        let (components, repeats) = triggerComponents(for: spec)
        // 기존 알림(본체+파생)을 먼저 지웁니다. 일회성을 지난 시각으로 옮겨도 예전 시각 알림이 남지 않습니다.
        removeAllUserNotifications(for: spec.id.uuidString)
        // 반복 알림은 기준시각이 과거여도 다음 발생에 매칭되므로 통과 (일회성만 미래 요구)
        guard spec.skipPlan != nil || repeats || spec.fireDate > Date() else { return }

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

        if let skipPlan = spec.skipPlan {
            scheduleSkipping(skipPlan, spec: spec, content: content)
            return
        }

        let request = UNNotificationRequest(
            identifier: spec.id.uuidString,
            content:    content,
            trigger:    UNCalendarNotificationTrigger(dateMatching: components, repeats: repeats)
        )
        center.add(request) { error in
            if error != nil {
                print("notification_schedule_failed")
            } else {
                let urgencyLabel = spec.urgency == .strong ? "🔴강함" : "🔵약함"
                print("notification_scheduled urgency=\(urgencyLabel)")
            }
        }

        // 일회성 strong → +5/+10분 재알림 체인 (한 번 놓쳐도 끝나지 않게)
        // 반복 태스크에는 매일 반복되는 잔소리가 되므로 걸지 않음
        if spec.urgency == .strong && spec.recurrenceRule == nil && !repeats {
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

    /// 건너뛸 회차를 뺀 반복 알림을 등록합니다. 반복 태스크라 팔로업 체인은 걸지 않습니다.
    private func scheduleSkipping(_ plan: SkipPlan, spec: AlarmSpec, content: UNNotificationContent) {
        let cal = Calendar.current
        let requests: [UNNotificationRequest]
        switch plan {
        case .otherWeekdays(let weekdays):
            let clock = cal.dateComponents([.hour, .minute], from: spec.fireDate)
            requests = weekdays.map { weekday in
                var components = clock
                components.weekday = weekday
                return UNNotificationRequest(
                    identifier: "\(spec.id.uuidString)-d\(weekday)",
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
                )
            }
        case .upcoming(let dates):
            requests = zip(Self.skipDayIdentifiers(for: spec.id.uuidString), dates).map { identifier, date in
                UNNotificationRequest(
                    identifier: identifier,
                    content: content,
                    trigger: UNCalendarNotificationTrigger(
                        dateMatching: cal.dateComponents([.year, .month, .day, .hour, .minute], from: date),
                        repeats: false
                    )
                )
            }
        }
        for request in requests {
            center.add(request) { error in
                if error != nil { print("notification_schedule_failed") }
            }
        }
        print("notification_scheduled_skipping count=\(requests.count)")
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
        print("notification_snoozed interval=\(Int(Self.snoozeInterval))")
    }

    /// 앱 안 알람 화면의 '5분 뒤 다시': 같은 할 일을 5분 뒤 강한 알림으로 한 번 더 알려줍니다.
    func scheduleSnooze(taskID: UUID, taskName: String) {
        let content = UNMutableNotificationContent()
        content.title = L.alarm.countdownTitle
        content.subtitle = L.alarm.notifSubtitleFollowUp
        content.body = "「\(taskName)」"
        content.userInfo = [
            "taskId": taskID.uuidString,
            "taskName": taskName,
            "urgency": Urgency.strong.rawValue,
        ]
        content.interruptionLevel = .timeSensitive
        content.sound = .defaultRingtone
        content.categoryIdentifier = Self.strongCategoryID

        let snoozeID = "\(taskID.uuidString)-snooze"
        center.removePendingNotificationRequests(withIdentifiers: [snoozeID])
        center.add(UNNotificationRequest(
            identifier: snoozeID,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: Self.snoozeInterval, repeats: false)
        ))
        print("overlay_snoozed interval=\(Int(Self.snoozeInterval))")
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

    /// "uuid" / "uuid-f1" / "uuid-f2" / "uuid-snooze" / "uuid-d1"…"uuid-d7" → uuid
    private static func baseTaskId(fromIdentifier identifier: String) -> UUID? {
        for follow in followUpIdentifiers(for: "") + skipDayIdentifiers(for: "") where identifier.hasSuffix(follow) {
            return UUID(uuidString: String(identifier.dropLast(follow.count)))
        }
        return UUID(uuidString: identifier)
    }

    /// 대기 중인 UN 알림이 하나라도 남아 있는 태스크 id
    func pendingTaskIds() async -> Set<UUID> {
        let requests = await center.pendingNotificationRequests()
        return Set(requests.compactMap { Self.baseTaskId(fromIdentifier: $0.identifier) })
    }

    /// 본체(반복 스케줄)는 유지하고 파생 알림만 제거 — 반복 태스크의 오늘 완료 시 사용
    func cancelFollowUps(taskIdString: String) {
        center.removePendingNotificationRequests(
            withIdentifiers: Self.followUpIdentifiers(for: taskIdString))
    }

    private func removeAllUserNotifications(for idString: String) {
        center.removePendingNotificationRequests(
            withIdentifiers: [idString] + Self.followUpIdentifiers(for: idString) + Self.skipDayIdentifiers(for: idString))
    }

    // MARK: - Spec Builders

    private func makeSpec(
        for task: AppTask,
        fireDate: Date,
        alarmKit: AlarmKitScheduleKind?,
        skipPlan: SkipPlan?
    ) -> AlarmSpec {
        AlarmSpec(
            id: task.id,
            title: task.task,
            category: task.category,
            recurrenceRule: task.recurrenceRule,
            hasDate: task.date != nil,
            fireDate: fireDate,
            urgency: task.urgency,
            alarmKitSchedule: alarmKit,
            skipPlan: skipPlan
        )
    }

    /// UN 트리거 규칙:
    /// weekly → 요일+시분 반복 / biweekly·monthly·yearly → 계산된 다음 1건
    /// date 없음 → 매일 / 그 외 → 일회성
    private func triggerComponents(for spec: AlarmSpec) -> (DateComponents, Bool) {
        let cal = Calendar.current
        if let rule = spec.recurrenceRule {
            switch rule {
            case "weekly":
                return (cal.dateComponents([.weekday, .hour, .minute], from: spec.fireDate), true)
            case "biweekly", "monthly", "yearly":
                return (cal.dateComponents(
                    [.year, .month, .day, .hour, .minute], from: spec.fireDate
                ), false)
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
    /// biweekly·monthly·yearly → RecurrenceEngine이 계산한 다음 발생일 fixed
    /// 일회성 → fixed
    private func alarmKitSchedule(
        for task: AppTask,
        fireDate: Date,
        skipPlan: SkipPlan?
    ) -> AlarmKitScheduleKind? {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: fireDate)
        let minute = cal.component(.minute, from: fireDate)

        // AlarmKit은 태스크마다 알람 하나라서 다가오는 회차는 첫 번째만 걸고, 다음은 포그라운드 재무장이 겁니다.
        switch skipPlan {
        case .otherWeekdays(let weekdays):
            return .weekdays(weekdays.map(Self.localeWeekday), hour: hour, minute: minute)
        case .upcoming(let dates):
            return dates.first.map { .fixed($0) }
        case nil:
            break
        }

        if let rule = task.recurrenceRule {
            switch rule {
            case "weekly":
                return .weekly(
                    weekday: Self.localeWeekday(cal.component(.weekday, from: fireDate)),
                    hour: hour, minute: minute
                )
            case "biweekly", "monthly", "yearly":
                return fireDate > Date() ? .fixed(fireDate) : nil
            default:
                return fireDate > Date() ? .fixed(fireDate) : nil
            }
        } else if task.date == nil {
            return .daily(hour: hour, minute: minute)
        }
        return fireDate > Date() ? .fixed(fireDate) : nil
    }

    /// Calendar weekday(1=일 … 7=토) → Locale.Weekday
    nonisolated private static func localeWeekday(_ calendarWeekday: Int) -> Locale.Weekday {
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
    private func parseTimeComponents(
        _ timeString: String,
        calendar: Calendar
    ) -> (hour: Int, minute: Int)? {
        let trimmed = timeString.trimmingCharacters(in: .whitespaces)

        for cachedFormatter in Self.timeFormatters {
            guard let formatter = cachedFormatter.copy() as? DateFormatter else { continue }
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            guard let parsed = formatter.date(from: trimmed) else { continue }
            let parts = calendar.dateComponents([.hour, .minute], from: parsed)
            if let hour = parts.hour, let minute = parts.minute {
                return (hour, minute)
            }
        }
        return nil
    }
}

/// Versioned per-account permission; signing out never grants another account access.
enum AIDataConsent {
    static let currentVersion = 2
    static let didChange = Notification.Name("mora.aiDataConsentChanged")

    static func isGranted(for userID: UUID? = nil, defaults: UserDefaults = .standard) -> Bool {
        AccountPreferences.integer(.aiDataConsentVersion, default: 0, for: userID, defaults: defaults) == currentVersion
    }

    static func setGranted(_ granted: Bool, for userID: UUID? = nil, defaults: UserDefaults = .standard) {
        AccountPreferences.set(granted ? currentVersion : 0, for: .aiDataConsentVersion, userID: userID, defaults: defaults)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
