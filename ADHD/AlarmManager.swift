import Foundation
import Combine
import UserNotifications
import SwiftUI

// MARK: - AlarmEntry
struct AlarmEntry: Identifiable {
    let id: UUID
    let taskName: String
}

// MARK: - AlarmManager
/// UNUserNotificationCenterDelegate + ObservableObject
/// 포그라운드에서 "강한 알림"이 도착하면 activeAlarm에 태스크를 세팅합니다.
final class AlarmManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {

    static let shared = AlarmManager()
    private override init() { super.init() }

    /// non-nil이면 AlarmOverlayView를 화면에 표시
    @Published var activeAlarm: AlarmEntry? = nil
    
    /// 알람 확인 시 호출될 클로저 (Task를 완료 상태로 변경하는 등의 용도)
    var onTaskConfirmed: ((UUID) -> Void)?

    // MARK: - Foreground 알림 수신
    /// 앱이 활성 상태일 때 알림이 도착하면 이 메서드가 호출됩니다.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        let urgencyRaw = userInfo["urgency"] as? String ?? Urgency.strong.rawValue
        let urgency    = Urgency(rawValue: urgencyRaw) ?? .strong

        if urgency == .strong {
            // 강한 알림: 오버레이 표시 + 시스템 배너 없음
            if let taskName = userInfo["taskName"] as? String,
               let taskIdStr = userInfo["taskId"] as? String,
               let taskId = UUID(uuidString: taskIdStr) {
                DispatchQueue.main.async {
                    self.activeAlarm = AlarmEntry(id: taskId, taskName: taskName)
                }
            }
            // 포그라운드에서는 시스템 배너를 띄우지 않고 오버레이로 처리
            completionHandler([.sound])
        } else {
            // 약한 알림: 일반 배너 표시
            completionHandler([.banner, .sound])
        }
    }

    /// 사용자가 알림 배너를 탭했을 때 (백그라운드 → 포그라운드 복귀)
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo  = response.notification.request.content.userInfo
        let urgencyRaw = userInfo["urgency"] as? String ?? Urgency.strong.rawValue
        let urgency    = Urgency(rawValue: urgencyRaw) ?? .strong

        if urgency == .strong,
           let taskName = userInfo["taskName"] as? String,
           let taskIdStr = userInfo["taskId"] as? String,
           let taskId = UUID(uuidString: taskIdStr) {
            DispatchQueue.main.async {
                self.activeAlarm = AlarmEntry(id: taskId, taskName: taskName)
            }
        }
        completionHandler()
    }

    // MARK: - Dismiss
    func dismiss() {
        if let alarm = activeAlarm {
            // 확인 시 자동 체크 실행
            onTaskConfirmed?(alarm.id)
        }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.4)) {
                self.activeAlarm = nil
            }
        }
    }
}
