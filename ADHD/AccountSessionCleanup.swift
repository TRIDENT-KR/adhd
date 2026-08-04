import AlarmKit
import Foundation
import SwiftData
import UserNotifications
import WidgetKit

enum AccountSessionCleanupReason: String {
    case signedOut
    case accountSwitch
    case invalidSession
    case deletionPending
    case deletionCompleted
}

extension Notification.Name {
    /// 화면에 남아 있는 음성·텍스트 초안 등 계정별 임시 상태를 즉시 비우는 신호입니다.
    static let accountSessionSensitiveStateReset = Notification.Name(
        "accountSessionSensitiveStateReset"
    )

    /// 서버가 특정 Mora 계정의 삭제를 완료했다는 인증 계층의 신호입니다.
    static let moraAccountDeletionCompleted = Notification.Name(
        "moraAccountDeletionCompleted"
    )
}

@MainActor
final class AccountSessionCleanupCoordinator {
    private enum SharedKey {
        static let widgetPayload = "widgetTaskPayload"
        static let pendingWidgetToggles = "pendingWidgetToggles"
        static let widgetDeepLink = "widgetDeepLink"
    }

    /// 일정 본문은 건드리지 않고 현재 계정의 로컬 노출·실행 경로만 잠급니다.
    func lockLocalExposure(
        taskManager: TaskManager,
        reason: AccountSessionCleanupReason
    ) async {
        cancelTaskNotifications(in: taskManager.modelContext)
        taskManager.modelContext = nil
        taskManager.isReady = false
        taskManager.undoDismissWorkItem?.cancel()
        taskManager.undoDismissWorkItem = nil
        taskManager.undoStack.removeAll(keepingCapacity: false)
        taskManager.showUndoSnackbar = false
        taskManager.undoSnackbarMessage = ""

        NotificationCenter.default.post(
            name: .accountSessionSensitiveStateReset,
            object: nil,
            userInfo: ["reason": reason.rawValue]
        )

        let inAppAlarmCoordinator = AlarmCoordinator.shared
        inAppAlarmCoordinator.onTaskConfirmed = nil
        await drainInAppAlarmQueue(inAppAlarmCoordinator)

        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.removeAllPendingNotificationRequests()
        notificationCenter.removeAllDeliveredNotifications()

        if let alarms = try? AlarmKit.AlarmManager.shared.alarms {
            for alarm in alarms {
                try? AlarmKit.AlarmManager.shared.cancel(id: alarm.id)
            }
        }

        _ = AlarmCompletionRelay.drain()

        if let defaults = UserDefaults(suiteName: appGroupID) {
            defaults.removeObject(forKey: SharedKey.widgetPayload)
            defaults.removeObject(forKey: SharedKey.pendingWidgetToggles)
            defaults.removeObject(forKey: SharedKey.widgetDeepLink)
            defaults.removeObject(forKey: SubscriptionManager.premiumFlagKey)
        }
        WidgetAccountScope.deactivate()
        AccountPreferences.deactivate()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// 진행 중인 AlarmKit 등록도 완료 직전 취소 레지스트리에 걸리도록 태스크별 취소를 먼저 수행합니다.
    private func cancelTaskNotifications(in context: ModelContext?) {
        guard let context else { return }
        do {
            let tasks = try context.fetch(FetchDescriptor<AppTask>())
            for task in tasks {
                NotificationManager.shared.cancelNotification(for: task)
            }
        } catch {
            print("account_notification_cleanup_fetch_failed")
        }
    }

    /// 재로그인한 계정의 미래 알림과 위젯만 현재 저장소에서 다시 구성합니다.
    func restoreLocalExposure(taskManager: TaskManager) {
        guard let context = taskManager.modelContext else { return }

        do {
            let tasks = try context.fetch(FetchDescriptor<AppTask>())
            for task in tasks where !task.isCompleted {
                NotificationManager.shared.scheduleNotification(for: task)
            }
            taskManager.writeWidgetSnapshot()
        } catch {
            print("account_local_exposure_restore_failed")
        }
    }

    /// AlarmCoordinator의 private 대기열은 공개 dismiss 경로로 소진하여 이전 계정 오버레이를 남기지 않습니다.
    private func drainInAppAlarmQueue(_ coordinator: AlarmCoordinator) async {
        for _ in 0..<256 {
            guard coordinator.activeAlarm != nil else { return }
            coordinator.dismiss()
            await Task.yield()
        }

        // 비정상적으로 큰 큐가 있어도 현재 화면에 이전 계정 알람을 노출하지 않습니다.
        coordinator.activeAlarm = nil
    }
}
