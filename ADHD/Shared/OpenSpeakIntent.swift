import AppIntents

// MARK: - Open Speak Intent
/// '말하기' 컨트롤(잠금 화면·제어 센터·동작 버튼)이 실행하는 의도.
/// ⚠️ 앱 타깃과 위젯 타깃 양쪽에 포함되는 공용 파일 — 컨트롤이 앱을 열려면 두 타깃에 같은 의도가 있어야 합니다.
/// openAppWhenRun이라 perform은 앱 프로세스에서 돌고, 앱이 넣어 둔 경로로 음성 탭을 엽니다.
/// (OpenURLIntent를 버튼에 바로 넣거나 opensIntent로 넘기면 제어 센터에서 앱이 열리지 않았습니다.)
struct OpenSpeakIntent: AppIntent {
    static let title: LocalizedStringResource = "Speak"
    static let isDiscoverable = false
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        SpeakIntentRoute.openVoice?()
        return .result()
    }
}

/// 위젯 타깃은 앱의 탭 이동 코드를 볼 수 없으므로, 앱이 실행될 때 여기에 경로를 넣어 둡니다.
enum SpeakIntentRoute {
    @MainActor static var openVoice: (() -> Void)?
}
