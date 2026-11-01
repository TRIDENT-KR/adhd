import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Speak Control (잠금 화면·제어 센터·동작 버튼)
/// 잠금 화면 아래 손전등·카메라 자리에 넣는 '말하기' 버튼입니다.
/// 누르면 Mora가 음성 탭으로 열립니다(OpenSpeakIntent, Shared). 녹음은 열린 뒤 사용자가 시작합니다(의도치 않은 녹음 방지).
/// 동작 버튼에서도 '제어 항목'으로 같은 컨트롤을 고를 수 있습니다.
/// 앱을 여는 지름길일 뿐이라 Pro가 아니어도 씁니다. AI 사용은 앱 안에서 횟수 제한을 그대로 받습니다.
struct SpeakControl: ControlWidget {
    static let kind = "SpeakControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenSpeakIntent()) {
                Label("Speak", systemImage: "mic.fill")
            }
        }
        .displayName("Speak")
        .description("Open Mora ready to speak.")
    }
}
