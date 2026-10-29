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

    /// 위젯에서 호출: 공유 저장소에서 태스크 스냅샷 읽기 (now가 속한 날 기준으로 고친 상태)
    static func read(for now: Date = Date()) -> WidgetDataPayload? {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: key) else {
            return nil
        }
        guard let payload = try? JSONDecoder().decode(WidgetDataPayload.self, from: data),
              let activeScope = WidgetAccountScope.active,
              payload.accountScope == activeScope else { return nil }
        return payload.normalized(for: now)
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

    /// 위젯이 잠긴 이유. nil이면 Pro라서 내용을 보여 줍니다.
    static var lockReason: WidgetLockReason? {
        let defaults = UserDefaults(suiteName: appGroupID)
        return WidgetLockReason.resolve(
            activeScope: WidgetAccountScope.active,
            premiumScope: defaults?.string(forKey: WidgetAccountScope.premiumScopeKey),
            premiumFlag: defaults?.object(forKey: "isPremiumUser") as? Bool
        )
    }
}

// MARK: - 위젯 잠금 이유
/// 위젯이 내용을 보여 줄 수 없을 때, 왜 그런지 한 문장으로 알려 주기 위한 이유입니다.
enum WidgetLockReason: Equatable {
    /// 앱이 아직 계정·Pro 상태를 남기지 않았어요 (업데이트·설치 직후 등). 앱을 한 번 열면 풀립니다.
    case needsAppOpen
    /// Pro가 아니에요. 로그인 없이 쓰는 앱이라(#76) 게스트에게도 로그인 대신 Pro만 안내합니다.
    case needsPro

    /// App Group에 남은 값으로 잠금 이유를 정합니다. Pro면 nil입니다.
    static func resolve(activeScope: String?, premiumScope: String?, premiumFlag: Bool?) -> WidgetLockReason? {
        guard let activeScope else { return .needsAppOpen }
        if activeScope == WidgetAccountScope.guest { return .needsPro }
        // Pro 여부가 지금 계정 것으로 아직 기록되지 않았으면, 앱을 한 번 열어야 알 수 있습니다.
        guard premiumScope == activeScope, let premiumFlag else { return .needsAppOpen }
        return premiumFlag ? nil : .needsPro
    }
}
