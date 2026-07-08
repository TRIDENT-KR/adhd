import Foundation
import Combine
import UserNotifications
import SwiftUI

// MARK: - AlarmEntry
struct AlarmEntry: Identifiable {
    let id: UUID
    let taskName: String
}

// MARK: - Alarm Completion Relay
/// 알림 "완료" 액션 / AlarmKit Stop 인텐트 → 태스크 완료를 앱으로 전달하는 App Group 큐.
/// 백그라운드에서 실행돼도 유실되지 않고, 앱이 살아 있으면 NotificationCenter로 즉시 처리됩니다.
enum AlarmCompletionRelay {
    static let queueKey = "pendingAlarmCompletions"

    static func enqueue(taskID: String) {
        let defaults = UserDefaults(suiteName: appGroupID)
        var queue = defaults?.stringArray(forKey: queueKey) ?? []
        queue.append(taskID)
        defaults?.set(queue, forKey: queueKey)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .alarmTaskCompleted, object: nil)
        }
    }
}

// MARK: - Notification Names
extension Notification.Name {
    /// 알림 액션/AlarmKit에서 태스크 완료가 큐에 적재됨 → TaskManager가 즉시 처리
    static let alarmTaskCompleted = Notification.Name("alarmTaskCompleted")
    /// 구독 상태(isPremium) 변경 → strong 태스크 백엔드 재라우팅
    static let premiumStatusChanged = Notification.Name("premiumStatusChanged")
    /// AlarmKit 권한 최초 획득 → 기존 strong 태스크를 시스템 알람으로 이관
    static let alarmBackendChanged = Notification.Name("alarmBackendChanged")
}

// MARK: - AlarmCoordinator
/// UNUserNotificationCenterDelegate + ObservableObject.
/// (구 AlarmManager — AlarmKit.AlarmManager와의 이름 충돌을 피해 리네임)
///
/// 표현 매트릭스:
/// - strong × Pro  : 포그라운드/탭 → 풀스크린 오버레이 (AlarmKit 거부 시 폴백 경로)
/// - strong × Free : 배너만 (D14 — 오버레이는 Pro 전용)
/// - weak          : 항상 배너만
/// - "완료" 액션    : 백그라운드 완료 처리 (앱 안 열림)
/// - "5분 뒤 다시"  : 스누즈 재등록
final class AlarmCoordinator: NSObject, ObservableObject, UNUserNotificationCenterDelegate {

    static let shared = AlarmCoordinator()
    private override init() { super.init() }

    /// non-nil이면 AlarmOverlayView를 화면에 표시
    @Published var activeAlarm: AlarmEntry? = nil

    /// 현재 알람 처리 중 도착한 대기 알람 큐
    private var pendingAlarms: [AlarmEntry] = []

    /// 알람 확인 시 호출될 클로저 (Task를 완료 상태로 변경하는 등의 용도)
    var onTaskConfirmed: ((UUID) -> Void)?

    /// D14: 풀스크린 오버레이는 Pro 전용
    private var isPremium: Bool {
        UserDefaults(suiteName: appGroupID)?.bool(forKey: SubscriptionManager.premiumFlagKey) ?? false
    }

    /// userInfo에서 urgency 추출. 값이 없으면 weak으로 간주 (오버레이 오발동 방지)
    private func urgency(from userInfo: [AnyHashable: Any]) -> Urgency {
        Urgency(rawValue: userInfo["urgency"] as? String ?? "") ?? .weak
    }

    // MARK: - Foreground 알림 수신
    /// 앱이 활성 상태일 때 알림이 도착하면 이 메서드가 호출됩니다.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo

        if urgency(from: userInfo) == .strong && isPremium {
            // 강한 알림(Pro): 오버레이 표시 + 시스템 배너 없음
            enqueueOverlay(from: userInfo)
            completionHandler([.sound])
        } else {
            // 약한 알림 또는 무료 사용자: 일반 배너 표시
            completionHandler([.banner, .sound])
        }
    }

    // MARK: - 알림 탭 / 액션 처리
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let taskIdStr = userInfo["taskId"] as? String

        switch response.actionIdentifier {
        case NotificationManager.doneActionID:
            // "완료" — 앱을 열지 않고 백그라운드에서 완료 처리
            if let taskIdStr {
                NotificationManager.shared.cancelFollowUps(taskIdString: taskIdStr)
                AlarmCompletionRelay.enqueue(taskID: taskIdStr)
            }

        case NotificationManager.snoozeActionID:
            // "5분 뒤 다시" — 동일 콘텐츠로 +5분 재등록
            NotificationManager.shared.scheduleSnooze(from: response.notification.request)

        case UNNotificationDefaultActionIdentifier:
            // 알림 본문 탭 (백그라운드 → 포그라운드 복귀)
            if urgency(from: userInfo) == .strong && isPremium {
                enqueueOverlay(from: userInfo)
            }

        default:
            break
        }
        completionHandler()
    }

    // MARK: - Overlay Queue
    private func enqueueOverlay(from userInfo: [AnyHashable: Any]) {
        guard let taskName = userInfo["taskName"] as? String,
              let taskIdStr = userInfo["taskId"] as? String,
              let taskId = UUID(uuidString: taskIdStr) else { return }
        DispatchQueue.main.async {
            let entry = AlarmEntry(id: taskId, taskName: taskName)
            if self.activeAlarm == nil {
                self.activeAlarm = entry
            } else {
                self.pendingAlarms.append(entry)
            }
        }
    }

    // MARK: - Dismiss
    func dismiss() {
        guard let alarm = activeAlarm else { return }
        let alarmId = alarm.id
        DispatchQueue.main.async {
            // onTaskConfirmed와 activeAlarm 변경을 같은 async 블록에서 처리해
            // 사이에 다른 alarm set이 끼어드는 race를 방지
            self.onTaskConfirmed?(alarmId)
            withAnimation(.easeInOut(duration: 0.4)) {
                if self.pendingAlarms.isEmpty {
                    self.activeAlarm = nil
                } else {
                    self.activeAlarm = self.pendingAlarms.removeFirst()
                }
            }
        }
    }
}
