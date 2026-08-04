import Foundation

// MARK: - Widget Data Store
/// App Group UserDefaults를 통해 메인 앱 ↔ 위젯 간 데이터를 교환합니다.
struct WidgetDataStore {
    private static let key = "widgetTaskPayload"

    /// 메인 앱에서 호출: 오늘의 태스크 스냅샷을 공유 저장소에 기록
    static func write(_ payload: WidgetDataPayload) {
        guard payload.accountScope == WidgetAccountScope.active,
              let defaults = UserDefaults(suiteName: appGroupID) else {
            print("⚠️ WidgetDataStore: App Group 접근 실패")
            return
        }
        do {
            let data = try JSONEncoder().encode(payload)
            defaults.set(data, forKey: key)
            print("📦 위젯 데이터 동기화 완료 (루틴 \(payload.routines.count)개, 일정 \(payload.appointments.count)개)")
        } catch {
            print("widget_snapshot_encode_failed")
        }
    }

    /// 위젯에서 호출: 공유 저장소에서 태스크 스냅샷 읽기
    static func read() -> WidgetDataPayload? {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: key) else {
            return nil
        }
        guard let payload = try? JSONDecoder().decode(WidgetDataPayload.self, from: data),
              let activeScope = WidgetAccountScope.active,
              payload.accountScope == activeScope else { return nil }
        return payload
    }

    /// D13: 메인 앱이 App Group에 기록한 Pro 여부 (위젯 잠금 게이팅)
    /// 키 부재(업데이트 직후 미기록) 시 false=잠금 — 메인 앱 1회 실행으로 해소
    static var isPremium: Bool {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let activeScope = WidgetAccountScope.active,
              defaults.string(forKey: WidgetAccountScope.premiumScopeKey) == activeScope else {
            return false
        }
        return defaults.bool(forKey: "isPremiumUser")
    }
}
