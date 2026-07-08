import Foundation
import AlarmKit

// MARK: - Mora Alarm Metadata
/// AlarmKit 알람 ↔ Live Activity 간에 전달되는 메타데이터.
/// ⚠️ 앱 타깃과 위젯 타깃 양쪽에 포함되는 공용 파일 — 타입 이름과 필드가 두 타깃에서 완전히 동일해야
/// ActivityKit이 Live Activity를 올바르게 매칭합니다.
struct MoraAlarmMetadata: AlarmMetadata {
    let taskName: String

    init(taskName: String) {
        self.taskName = taskName
    }
}
