import SwiftUI

// MARK: - AlarmOverlayView
/// 강한 알림 발생 시 화면 전체를 덮는 풀스크린 알람 UI.
/// AlarmManager.shared.activeAlarm이 non-nil일 때 MainTabView 위에 표시됩니다.
struct AlarmOverlayView: View {
    let alarm: AlarmEntry

    @StateObject private var alarmManager = AlarmManager.shared
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

                        Text(L.alarm.subtitle)
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
                        Text(L.alarm.dismiss)
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
                .accessibilityLabel(L.alarm.a11yDismiss())
                .accessibilityHint(L.alarm.a11yHint(alarm.taskName))

                // 스와이프 힌트
                HStack(spacing: 6) {
                    Image(systemName: "hand.tap")
                        .font(.caption)
                    Text(L.alarm.tapHint)
                        .font(.caption)
                }
                .foregroundColor(.white.opacity(0.5))
                .padding(.bottom, 40)
                .accessibilityHidden(true)
            }
        }
        .scaleEffect(scale)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L.alarm.a11yLabel(alarm.taskName))
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
