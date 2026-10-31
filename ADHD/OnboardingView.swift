import SwiftUI
import SwiftData

// MARK: - Onboarding View
/// F1/D18: 처음 실행 때 1회 표시되는 경량 온보딩 2장 (스킵 가능).
/// 1장은 한 줄 가치 제안, 2장은 말하는 예시이고 2장의 시작하기가 끝입니다.
/// D21: 완료 시 hasSeenVoiceOnboarding도 true → Home 가이드 자동 표시 생략.
///      스킵 시에만 첫 Home 진입 때 가이드가 자동 1회 표시된다.
/// D22: 기존 사용자(태스크 보유)는 렌더 전에 자동 통과.
struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("hasSeenVoiceOnboarding") private var hasSeenVoiceOnboarding = false
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var langManager = LocalizationManager.shared
    @State private var page = 0    // 0...1
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 52
    @ScaledMetric(relativeTo: .largeTitle) private var page2TitleSize: CGFloat = 42

    private let pageCount = 2

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                topBar

                TabView(selection: $page) {
                    scrollable(pageOne).tag(0)
                    scrollable(pageTwo).tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                // 하단 버튼: 브랜드 색 대신 배경에 묻는 차분한 버튼 (1장 다음 / 2장 시작하기)
                Group {
                    if page < pageCount - 1 {
                        Button(action: {
                            withAnimation(reduceMotion ? .none : .easeInOut(duration: 0.3)) {
                                page += 1
                            }
                        }) {
                            HStack(spacing: 8) {
                                Text(L.onboarding.next)
                                Image(systemName: "arrow.right")
                                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                                    .accessibilityHidden(true)
                            }
                        }
                        .accessibilityLabel(L.onboarding.next)
                    } else {
                        Button(action: complete) {
                            Text(L.onboarding.start)
                        }
                        .accessibilityLabel(L.onboarding.start)
                    }
                }
                .buttonStyle(CalmButtonStyle())
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
        }
        .onAppear { skipIfExistingUser() }
    }

    // MARK: - Chrome

    /// 따뜻한 종이 바탕에 오른쪽 아래 테라코타, 왼쪽 아래 청록 빛을 아주 옅게 깝니다.
    private var background: some View {
        ZStack {
            DesignSystem.Colors.background
            RadialGradient(colors: [DesignSystem.Colors.primaryContainer.opacity(0.26), .clear],
                           center: UnitPoint(x: 0.88, y: 0.78), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [DesignSystem.Colors.tertiary.opacity(0.07), .clear],
                           center: .bottomLeading, startRadius: 0, endRadius: 380)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    /// 왼쪽 위 진행 막대, 오른쪽 위 건너뛰기 (마지막 장은 시작하기가 끝이므로 숨깁니다)
    private var topBar: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Capsule()
                        .fill(index == page
                              ? DesignSystem.Colors.onSurface
                              : DesignSystem.Colors.onSurface.opacity(0.12))
                        .frame(width: index == page ? 28 : 14, height: 5)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: page)
            .accessibilityHidden(true)

            Spacer()

            if page < pageCount - 1 {
                Button(action: skip) {
                    Text(L.onboarding.skip)
                        .font(.callout.weight(.semibold))
                        .foregroundColor(DesignSystem.Colors.onSurfaceMeta)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NoEffectButtonStyle())
                .accessibilityLabel(L.onboarding.skip)
            }
        }
        .padding(.leading, 28)
        .padding(.trailing, 20)
        .frame(height: 52)
    }

    // MARK: - Pages

    /// 1장: 한 줄 가치 제안. 큰 제목 하나가 시선이 머무는 곳입니다.
    private var pageOne: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L.onboarding.page1Title)
                .font(.system(size: heroSize, weight: .heavy))
                .tracking(-heroSize * 0.04)
                .foregroundColor(DesignSystem.Colors.onSurface)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .accessibilityAddTraits(.isHeader)
            Text(L.onboarding.page1Body)
                .font(.title3)
                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)

            Spacer(minLength: 40)
            OnboardingMicOrb()
                .frame(maxWidth: .infinity)
            Spacer(minLength: 40)
        }
        .padding(.horizontal, 28)
        .padding(.top, 36)
        .accessibilityElement(children: .combine)
        .accessibilityHint(L.onboarding.pageHint(1, total: pageCount))
    }

    /// 2장: 이렇게 말하면 이렇게 정리된다는 대화 예시
    private var pageTwo: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L.onboarding.page2Title)
                .font(.system(size: page2TitleSize, weight: .heavy))
                .tracking(-page2TitleSize * 0.035)
                .foregroundColor(DesignSystem.Colors.onSurface)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 8) {
                ForEach(L.onboarding.examples, id: \.self) { example in
                    exampleExchange(example)
                }
            }
            .padding(.top, 40)

            Spacer(minLength: 24)
        }
        .padding(.horizontal, 24)
        .padding(.top, 36)
        .accessibilityElement(children: .combine)
        .accessibilityHint(L.onboarding.pageHint(2, total: pageCount))
    }

    /// 큰 글씨에서도 내용이 잘리지 않게 페이지마다 스크롤되게 하고, 평소에는 한 화면에 맞춥니다.
    private func scrollable<Content: View>(_ content: Content) -> some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// 오른쪽에 내가 한 말, 왼쪽에 Mora가 정리한 결과
    private func exampleExchange(_ example: OnboardingStrings.Example) -> some View {
        VStack(spacing: 8) {
            Text(example.said)
                .font(.body.weight(.semibold))
                .foregroundColor(DesignSystem.Colors.onSurface)
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
                .background(
                    UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20,
                                           bottomTrailingRadius: 6, topTrailingRadius: 20, style: .continuous)
                        .fill(DesignSystem.Colors.onSurfaceVariant.opacity(0.08))
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 48)

            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.bold))
                    .foregroundColor(DesignSystem.Colors.tertiary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(DesignSystem.Colors.tertiary.opacity(0.12)))
                Text(resultText(example))
                    .font(.subheadline)
            }
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .padding(.vertical, 11)
            .background(
                UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 6,
                                       bottomTrailingRadius: 18, topTrailingRadius: 18, style: .continuous)
                    .fill(DesignSystem.Colors.surfaceContainerLowest)
                    .shadow(color: DesignSystem.Colors.onSurfaceVariant.opacity(0.07), radius: 15, y: 10)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 48)
            .padding(.bottom, 12)
        }
    }

    private func resultText(_ example: OnboardingStrings.Example) -> AttributedString {
        var name = AttributedString(example.name)
        name.font = .subheadline.weight(.bold)
        name.foregroundColor = DesignSystem.Colors.onSurface
        var detail = AttributedString(example.detail)
        detail.foregroundColor = DesignSystem.Colors.onSurfaceVariant
        return name + detail
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

/// 온보딩 1장의 마이크 원. 4초 숨쉬기 (모션 줄이기면 멈춤)
private struct OnboardingMicOrb: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(DesignSystem.Colors.primaryContainer.opacity(0.07))
                .frame(width: 340, height: 340)
            Circle()
                .fill(DesignSystem.Colors.primaryContainer.opacity(0.14))
                .frame(width: 260, height: 260)
            Circle()
                .fill(RadialGradient(
                    colors: [Color(hex: "#EDB096"), DesignSystem.Colors.primaryContainer, DesignSystem.Colors.primary],
                    center: UnitPoint(x: 0.32, y: 0.28), startRadius: 0, endRadius: 150))
                .frame(width: 176, height: 176)
                .shadow(color: DesignSystem.Colors.primary.opacity(0.32), radius: 40, y: 18)
            Image(systemName: "mic.fill")
                .font(.system(size: 60))
                .foregroundColor(DesignSystem.Colors.onPrimary)
        }
        .scaleEffect(breathing ? 1.04 : 1.0)
        .frame(height: 300)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
        .accessibilityHidden(true)
    }
}
