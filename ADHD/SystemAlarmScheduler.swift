import Foundation
import SwiftUI
import AlarmKit
import AppIntents

// MARK: - AlarmKit Schedule Kind
/// NotificationManager가 AppTask로부터 계산해 전달하는 AlarmKit 스케줄 형태.
/// (AlarmKit 타입 의존을 SystemAlarmScheduler 안에 격리하기 위해 Foundation 타입만 사용)
enum AlarmKitScheduleKind: Sendable {
    /// 매일 반복 루틴 (date == nil)
    case daily(hour: Int, minute: Int)
    /// 매주 같은 요일 반복
    case weekly(weekday: Locale.Weekday, hour: Int, minute: Int)
    /// 일회성 또는 biweekly/monthly/yearly의 "다음 발생일" (재무장 방식)
    case fixed(Date)
}

// MARK: - Alarm Spec
/// 알림/알람 스케줄에 필요한 값 스냅샷.
/// AppTask(@Model)는 Sendable이 아니므로 Task 경계를 넘기 전에 값으로 복사합니다.
struct AlarmSpec: Sendable {
    let id: UUID
    let title: String
    let category: String        // "Routine" | "Appointment"
    let recurrenceRule: String?
    let hasDate: Bool
    let fireDate: Date          // remindBefore가 이미 반영된 기준 시각
    let urgency: Urgency
    let alarmKitSchedule: AlarmKitScheduleKind?
}

// MARK: - Mark Task Done Intent
/// AlarmKit 알람의 Stop("완료") 버튼이 실행하는 인텐트.
/// LiveActivityIntent는 앱 프로세스에서 실행되므로(앱이 꺼져 있으면 백그라운드 기동)
/// App Group 큐에 적재 → 앱이 다음 활성화(또는 즉시 수신)에 태스크를 완료 처리합니다.
struct MarkTaskDoneIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Complete Task"
    static var isDiscoverable: Bool = false

    @Parameter(title: "Task ID")
    var taskID: String

    init() {}

    init(taskID: String) {
        self.taskID = taskID
    }

    func perform() async throws -> some IntentResult {
        AlarmCompletionRelay.enqueue(taskID: taskID)
        NotificationManager.shared.cancelFollowUps(taskIdString: taskID)
        return .result()
    }
}

// MARK: - System Alarm Scheduler
/// iOS 26 AlarmKit 래퍼 — Pro 사용자의 strong 태스크를 시스템 알람으로 승격합니다.
/// 시스템 알람은 앱이 종료된 상태에서도 잠금화면 풀스크린으로 울리고 무음/집중 모드를 관통합니다.
/// ⚠️ 이 앱의 AlarmCoordinator(구 AlarmManager)와 이름이 겹치므로
///    AlarmKit 심볼은 항상 `AlarmKit.AlarmManager`로 완전 수식합니다.
final class SystemAlarmScheduler: Sendable {

    static let shared = SystemAlarmScheduler()
    private init() {}

    /// 스누즈("5분 뒤 다시") 카운트다운 길이 (초)
    private static let snoozeDuration: TimeInterval = 300

    // MARK: - Authorization

    var isAuthorized: Bool {
        AlarmKit.AlarmManager.shared.authorizationState == .authorized
    }

    /// 미결정 상태면 이 자리에서 권한을 요청합니다 (Pro 사용자가 strong 태스크를 처음 저장하는 순간).
    /// 거부 상태면 조용히 false → 호출부가 UN 폴백으로 전환.
    func ensureAuthorized() async -> Bool {
        let manager = AlarmKit.AlarmManager.shared
        switch manager.authorizationState {
        case .authorized:
            return true
        case .denied:
            return false
        case .notDetermined:
            let state = (try? await manager.requestAuthorization()) ?? .denied
            if state == .authorized {
                // 기존 strong 태스크들을 AlarmKit으로 이관하도록 앱에 알림
                await MainActor.run {
                    NotificationCenter.default.post(name: .alarmBackendChanged, object: nil)
                }
                return true
            }
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Schedule

    func schedule(_ spec: AlarmSpec) async {
        guard let kind = spec.alarmKitSchedule else { return }
        let manager = AlarmKit.AlarmManager.shared

        // 울리는 중/스누즈 카운트다운 중인 알람은 건드리지 않음 (포그라운드 재무장으로부터 보호)
        if let existing = try? manager.alarms.first(where: { $0.id == spec.id }),
           existing.state != .scheduled {
            return
        }

        let schedule: AlarmKit.Alarm.Schedule
        switch kind {
        case .daily(let hour, let minute):
            schedule = .relative(.init(
                time: .init(hour: hour, minute: minute),
                repeats: .weekly([.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday])
            ))
        case .weekly(let weekday, let hour, let minute):
            schedule = .relative(.init(
                time: .init(hour: hour, minute: minute),
                repeats: .weekly([weekday])
            ))
        case .fixed(let date):
            guard date > Date() else { return }
            schedule = .fixed(date)
        }

        let snoozeButton = AlarmButton(
            text: Self.resource(L.alarm.snoozeAction),
            textColor: .white,
            systemImageName: "zzz"
        )
        let presentation = AlarmPresentation(
            alert: .init(
                title: Self.resource(spec.title),
                secondaryButton: snoozeButton,
                secondaryButtonBehavior: .countdown
            ),
            countdown: .init(title: Self.resource(L.alarm.countdownTitle))
        )
        let attributes = AlarmAttributes(
            presentation: presentation,
            metadata: MoraAlarmMetadata(taskName: spec.title),
            tintColor: Color(red: 0x93 / 255.0, green: 0x4A / 255.0, blue: 0x2E / 255.0)
        )
        let configuration = AlarmKit.AlarmManager.AlarmConfiguration(
            countdownDuration: AlarmKit.Alarm.CountdownDuration(preAlert: nil, postAlert: Self.snoozeDuration),
            schedule: schedule,
            attributes: attributes,
            stopIntent: MarkTaskDoneIntent(taskID: spec.id.uuidString)
        )

        do {
            try? manager.cancel(id: spec.id)   // 동일 id 갱신을 위한 선취소 (미존재 시 무해)
            _ = try await manager.schedule(id: spec.id, configuration: configuration)
            print("⏰ [AlarmKit] 시스템 알람 등록: \(spec.title)")
        } catch {
            print("❌ [AlarmKit] 등록 실패(\(error.localizedDescription)) — UN 폴백")
            await MainActor.run {
                NotificationManager.shared.scheduleUserNotification(spec)
            }
        }
    }

    // MARK: - Cancel

    func cancel(id: UUID) {
        try? AlarmKit.AlarmManager.shared.cancel(id: id)
    }

    // MARK: - Helpers

    /// 런타임 문자열 → LocalizedStringResource (키 조회 실패 시 원문 그대로 표시됨)
    private static func resource(_ string: String) -> LocalizedStringResource {
        LocalizedStringResource(String.LocalizationValue(string))
    }
}
