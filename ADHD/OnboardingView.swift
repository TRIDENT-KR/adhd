import SwiftUI
import SwiftData

// MARK: - Onboarding View
/// F1/D18: 로그인 직후 1회 표시되는 경량 온보딩 3장 (스킵 가능).
/// D21: 완료 시 hasSeenVoiceOnboarding도 true → Home 가이드 자동 표시 생략.
///      스킵 시에만 첫 Home 진입 때 가이드가 자동 1회 표시된다.
/// D22: 기존 사용자(태스크 보유)는 렌더 전에 자동 통과.
struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("hasSeenVoiceOnboarding") private var hasSeenVoiceOnboarding = false
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var langManager = LocalizationManager.shared
    @State private var page = 0    // 0...2

    var body: some View {
        ZStack {
            DesignSystem.Colors.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // 상단 Skip 바 — 3장은 CTA가 종착이므로 1·2장에서만 노출
                HStack {
                    Spacer()
                    if page < 2 {
                        Button(action: skip) {
                            Text(L.onboarding.skip)
                                .font(DesignSystem.Typography.labelSm)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.6))
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(NoEffectButtonStyle())
                        .accessibilityLabel(L.onboarding.skip)
                    }
                }
                .padding(.horizontal, 24)
                .frame(height: 52)

                TabView(selection: $page) {
                    pageOne.tag(0)
                    pageTwo.tag(1)
                    pageThree.tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                // 커스텀 페이지 도트 — 기본 UIPageControl의 중성 회색 회피 (디자인 금기 #1)
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(index == page
                                  ? DesignSystem.Colors.primary
                                  : DesignSystem.Colors.onSurfaceVariant.opacity(0.2))
                            .frame(width: index == page ? 8 : 6,
                                   height: index == page ? 8 : 6)
                    }
                }
                .padding(.bottom, 20)
                .accessibilityHidden(true)

                // 하단 컨트롤: 1·2장 Next(텍스트 버튼) / 3장 Start CTA
                Group {
                    if page < 2 {
                        Button(action: {
                            withAnimation(reduceMotion ? .none : .easeInOut(duration: 0.3)) {
                                page += 1
                            }
                        }) {
                            Text(L.onboarding.next)
                                .font(DesignSystem.Typography.titleSm)
                                .foregroundColor(DesignSystem.Colors.primary)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(NoEffectButtonStyle())
                        .accessibilityLabel(L.onboarding.next)
                    } else {
                        Button(action: complete) {
                            Text(L.onboarding.start)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SatisfyingButtonStyle(color: DesignSystem.Colors.primary))
                        .padding(.horizontal, 32)
                        .accessibilityLabel(L.onboarding.start)
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .onAppear { skipIfExistingUser() }
    }

    // MARK: - Pages

    /// 1장: 가치 제안
    private var pageOne: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(DesignSystem.Colors.primary)
                .accessibilityHidden(true)
            Text(L.onboarding.page1Title)
                .font(DesignSystem.Typography.displayLg)
                .foregroundColor(DesignSystem.Colors.primary)
                .tracking(-0.5)
            Text(L.onboarding.page1Body)
                .font(DesignSystem.Typography.bodyMd)
                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Page 1 of 3")
    }

    /// 2장: 예시 명령어 (VoiceGuideSheet의 행 스타일 재사용 — D21 중복 해소의 근거)
    private var pageTwo: some View {
        VStack(spacing: 20) {
            Text(L.voice.guideTitle)
                .font(.title2.weight(.semibold))
                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)

            VStack(spacing: 16) {
                exampleRow(icon: "plus.circle.fill", text: L.voice.exampleAdd, color: DesignSystem.Colors.tertiary)
                exampleRow(icon: "calendar.circle.fill", text: L.voice.exampleAppointment, color: DesignSystem.Colors.primary)
                exampleRow(icon: "minus.circle.fill", text: L.voice.exampleDelete, color: Color.red.opacity(0.7))
            }
        }
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Page 2 of 3")
    }

    /// 3장: 시작 CTA로 이어지는 마무리
    private var pageThree: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundColor(DesignSystem.Colors.tertiary)
                .accessibilityHidden(true)
            Text(L.onboarding.page3Title)
                .font(DesignSystem.Typography.displayLg)
                .foregroundColor(DesignSystem.Colors.primary)
                .tracking(-0.5)
            Text(L.onboarding.page3Body)
                .font(DesignSystem.Typography.bodyMd)
                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Page 3 of 3")
    }

    private func exampleRow(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(color)
                .frame(width: 36)
            Text(text)
                .font(.body.weight(.medium))
                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(DesignSystem.Colors.surfaceContainerLow)
        )
    }

    // MARK: - Actions

    private func complete() {
        Haptic.impact(.medium)
        hasSeenVoiceOnboarding = true      // D21: 예시를 이미 봤으므로 Home 가이드 자동 표시 생략
        hasCompletedOnboarding = true      // 플래그 변경 → MyApp 분기가 MainTabView로 전환
    }

    private func skip() {
        hasCompletedOnboarding = true      // D21: 가이드는 첫 Home 진입 때 자동 1회
    }

    /// D22: 기존 사용자(태스크 1개 이상)는 온보딩이 렌더되기 전에 통과시킨다
    private func skipIfExistingUser() {
        let count = (try? modelContext.fetchCount(FetchDescriptor<AppTask>())) ?? 0
        if count > 0 {
            hasCompletedOnboarding = true
        }
    }
}
