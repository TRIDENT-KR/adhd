import SwiftUI
import Combine

// MARK: - AlarmOverlayView
/// 강한 알림 발생 시 화면 전체를 덮는 풀스크린 알람 UI.
/// AlarmCoordinator.shared.activeAlarm이 non-nil일 때 MainTabView 위에 표시됩니다.
struct AlarmOverlayView: View {
    let alarm: AlarmEntry

    @StateObject private var alarmManager = AlarmCoordinator.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scale: CGFloat = 0.85
    @State private var pulseOpacity: CGFloat = 0.0
    @State private var rippleScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            // 배경: 블러 + 딥 다크
            Color.black.opacity(0.85)
                .ignoresSafeArea()

            // 리플 배경 애니메이션
            if !reduceMotion {
                Circle()
                    .fill(Color.red.opacity(0.15))
                    .frame(width: 300, height: 300)
                    .scaleEffect(rippleScale)
                    .opacity(pulseOpacity)
                    .animation(
                        .easeOut(duration: 1.4).repeatForever(autoreverses: false),
                        value: rippleScale
                    )
                    .accessibilityHidden(true)

                Circle()
                    .fill(Color.red.opacity(0.1))
                    .frame(width: 200, height: 200)
                    .scaleEffect(rippleScale * 0.8)
                    .opacity(pulseOpacity * 0.8)
                    .animation(
                        .easeOut(duration: 1.4).delay(0.35).repeatForever(autoreverses: false),
                        value: rippleScale
                    )
                    .accessibilityHidden(true)
            }

            // 메인 카드
            VStack(spacing: 36) {
                Spacer()

                // 아이콘 + 레이블
                VStack(spacing: 20) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.red.opacity(0.8), Color.orange.opacity(0.7)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 96, height: 96)
                            .shadow(color: Color.red.opacity(0.5), radius: 20, x: 0, y: 8)

                        Image(systemName: "bell.badge.fill")
                            .font(.largeTitle.weight(.semibold))
                            .foregroundColor(.white)
                            .symbolEffect(.bounce, options: reduceMotion ? .nonRepeating : .repeating)
                    }
                    .accessibilityHidden(true)

                    VStack(spacing: 8) {
                        Text(alarm.taskName)
                            .font(.title.weight(.bold))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                            .lineLimit(nil)
                            .minimumScaleFactor(0.7)
                            .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 3)

                        Text(L.alarm.overlaySubtitle)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.white.opacity(0.75))
                    }
                }

                Spacer()

                // 확인 버튼
                Button(action: {
                    Haptic.impact(.heavy)
                    alarmManager.dismiss()
                }) {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3.weight(.semibold))
                        Text(L.alarm.overlayConfirm)
                            .font(.title3.weight(.bold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 64)
                    .background(
                        LinearGradient(
                            colors: [Color.red, Color.orange],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(20)
                    .shadow(color: Color.red.opacity(0.5), radius: 12, x: 0, y: 6)
                    .padding(.horizontal, 40)
                }
                .buttonStyle(AlarmDismissButtonStyle())
                .accessibilityLabel(L.alarm.overlayConfirm)
                .accessibilityHint(L.alarm.overlayA11yHint(alarm.taskName))

                // 스와이프 힌트
                HStack(spacing: 6) {
                    Image(systemName: "hand.tap")
                        .font(.caption)
                    Text(L.alarm.overlayHint)
                        .font(.caption)
                }
                .foregroundColor(.white.opacity(0.5))
                .padding(.bottom, 40)
                .accessibilityHidden(true)
            }
        }
        .scaleEffect(scale)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L.alarm.overlayA11yLabel(alarm.taskName))
        .onAppear {
            if reduceMotion {
                scale = 1.0
            } else {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                    scale = 1.0
                }
                // 리플 애니메이션 시작
                pulseOpacity = 0.8
                rippleScale = 2.2
            }
            // 강한 햅틱 루프 (3회)
            for i in 0...2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.8) {
                    Haptic.notification(.warning)
                }
            }
        }
    }
}

// MARK: - Dismiss Button Style
private struct AlarmDismissButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(reduceMotion ? .none : .easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Overlay Window
/// 알람 오버레이를 앱 화면과 별개인 창에 띄웁니다.
/// 화면 안의 fullScreenCover는 설정·빠른 추가·페이월 같은 시트가 이미 떠 있으면 표시되지 못해,
/// 강한 알림이 소리만 나고 완료·스누즈 화면이 나오지 않았습니다.
@MainActor
final class AlarmOverlayWindowPresenter {
    static let shared = AlarmOverlayWindowPresenter()
    private init() {}

    private var window: UIWindow?
    private var subscription: AnyCancellable?

    /// 저장소가 열린 뒤 한 번 호출합니다. 여러 번 불러도 구독은 하나입니다.
    func start() {
        guard subscription == nil else { return }
        subscription = AlarmCoordinator.shared.$activeAlarm
            .removeDuplicates { $0?.id == $1?.id }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] alarm in self?.show(alarm) }
    }

    private func show(_ alarm: AlarmEntry?) {
        guard let alarm else {
            hide()
            return
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }

        let host = UIHostingController(rootView: AlarmOverlayView(alarm: alarm))
        host.view.backgroundColor = .clear
        let overlayWindow = window ?? UIWindow(windowScene: scene)
        overlayWindow.windowLevel = .alert + 1
        overlayWindow.rootViewController = host
        overlayWindow.makeKeyAndVisible()
        window = overlayWindow
    }

    private func hide() {
        guard let overlayWindow = window else { return }
        overlayWindow.isHidden = true
        overlayWindow.rootViewController = nil
        window = nil
        // 알람 전에 쓰던 앱 창으로 키 입력·VoiceOver 초점을 돌려줍니다.
        overlayWindow.windowScene?.windows.first { $0 !== overlayWindow && !$0.isHidden }?.makeKey()
    }
}
