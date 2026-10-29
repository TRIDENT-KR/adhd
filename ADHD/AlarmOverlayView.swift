import SwiftUI
import Combine

// MARK: - AlarmOverlayView
/// 강한 알림이 울릴 때 화면 전체를 덮는 알람 UI (AlarmOverlayWindowPresenter가 별도 창에 띄움).
/// DESIGN.md의 차분한 톤: 따뜻한 바탕, 4초 호흡 펄스, '다 했어요'와 '5분 뒤 다시' 두 선택지.
struct AlarmOverlayView: View {
    let alarm: AlarmEntry

    @StateObject private var alarmManager = AlarmCoordinator.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// DESIGN.md 'Voice Pulse': 4초에 한 번 1.0 ↔ 1.1로 숨 쉬듯 커졌다 작아집니다.
    @State private var isBreathing = false

    var body: some View {
        ZStack {
            DesignSystem.Colors.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 32) {
                    ZStack {
                        Circle()
                            .fill(DesignSystem.Colors.primary.opacity(0.10))
                            .frame(width: 220, height: 220)
                            .scaleEffect(isBreathing ? 1.1 : 1.0)
                        Circle()
                            .fill(DesignSystem.Colors.primary.opacity(0.16))
                            .frame(width: 156, height: 156)
                            .scaleEffect(isBreathing ? 1.05 : 1.0)
                        Circle()
                            .fill(DesignSystem.Gradients.primaryCTA)
                            .frame(width: 96, height: 96)
                        Image(systemName: "bell.fill")
                            .font(.system(size: 38, weight: .semibold))
                            .foregroundColor(DesignSystem.Colors.onPrimary)
                    }
                    .accessibilityHidden(true)

                    VStack(spacing: 10) {
                        Text(alarm.taskName)
                            .font(.title.weight(.bold))
                            .foregroundColor(DesignSystem.Colors.onSurface)
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.7)
                        Text(L.alarm.overlaySubtitle)
                            .font(.body)
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 32)
                }

                Spacer()

                VStack(spacing: 6) {
                    Button(action: {
                        Haptic.impact(.medium)
                        alarmManager.dismiss()
                    }) {
                        Text(L.alarm.overlayConfirm)
                            .font(.title3.weight(.bold))
                            .foregroundColor(DesignSystem.Colors.onPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 58)
                            .background(Capsule().fill(DesignSystem.Gradients.primaryCTA))
                    }
                    .buttonStyle(PressScaleButtonStyle())
                    .accessibilityHint(L.alarm.overlayA11yHint(alarm.taskName))

                    // 완료하지 않고 알람만 미루기 (완료 버튼과 동작을 분리)
                    Button(action: {
                        Haptic.impact(.light)
                        alarmManager.snooze()
                    }) {
                        Text(L.alarm.overlaySnooze)
                            .font(.body.weight(.semibold))
                            .foregroundColor(DesignSystem.Colors.primary)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 52)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScaleButtonStyle())
                    .accessibilityHint(L.alarm.overlaySnoozeA11yHint)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L.alarm.overlayA11yLabel(alarm.taskName))
        .onAppear {
            // 경고 진동은 한 번만 (예전 3회 연속은 불안을 키움)
            Haptic.notification(.warning)
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                isBreathing = true
            }
        }
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
