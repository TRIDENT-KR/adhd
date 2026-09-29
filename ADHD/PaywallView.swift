import SwiftUI
import StoreKit

// MARK: - Paywall View
struct PaywallView: View {
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedProductID: String? = SubscriptionProductID.yearly.rawValue
    @State private var showError: Bool = false

    private var selectedProduct: Product? {
        subscriptionManager.products.first { $0.id == selectedProductID }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    DesignSystem.Colors.background,
                    DesignSystem.Colors.primary.opacity(0.08)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    headerSection

                    planSection
                        .padding(.top, 28)

                    ctaSection
                        .padding(.top, 24)

                    featuresSection
                        .padding(.top, 32)

                    footerSection
                        .padding(.top, 24)
                        .padding(.bottom, 40)
                }
                .padding(.horizontal, 24)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(L.settings.done) { dismiss() }
                    .foregroundColor(DesignSystem.Colors.primary)
            }
        }
        .alert(L.paywall.purchaseErrorTitle, isPresented: $showError) {
            Button(L.voice.confirmButton, role: .cancel) { subscriptionManager.purchaseError = nil }
        } message: {
            Text(subscriptionManager.purchaseError ?? "")
        }
        .onChange(of: subscriptionManager.purchaseError) { _, error in
            showError = error != nil
        }
        .task {
            if subscriptionManager.products.isEmpty {
                await subscriptionManager.loadProducts()
            }
        }
    }

    // MARK: - Header
    private var headerSection: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(DesignSystem.Colors.primary.opacity(0.12))
                    .frame(width: 80, height: 80)
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 36))
                    .foregroundColor(DesignSystem.Colors.primary)
            }
            .padding(.top, 32)

            Text(L.paywall.title)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(DesignSystem.Colors.primary)
                .multilineTextAlignment(.center)

            Text(L.paywall.subtitle)
                .font(DesignSystem.Typography.bodyMd)
                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.8))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
    }

    // MARK: - Plan Selection
    private var planSection: some View {
        VStack(spacing: 10) {
            Text(L.paywall.choosePlan)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)

            if subscriptionManager.products.isEmpty {
                if subscriptionManager.productsLoadFailed {
                    VStack(spacing: 12) {
                        Text(L.paywall.loadPlansFailed)
                            .font(DesignSystem.Typography.labelSm)
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.6))
                        Button {
                            Task { await subscriptionManager.loadProducts() }
                        } label: {
                            Text(L.paywall.retry)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(DesignSystem.Colors.primary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    HStack {
                        ProgressView()
                            .tint(DesignSystem.Colors.primary)
                        Text(L.paywall.loadingPlans)
                            .font(DesignSystem.Typography.labelSm)
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            } else {
                ForEach(subscriptionManager.products, id: \.id) { product in
                    PlanCard(
                        product: product,
                        isSelected: selectedProductID == product.id,
                        badgeText: product.id == SubscriptionProductID.yearly.rawValue ? yearlyBadgeText : nil
                    ) {
                        selectedProductID = product.id
                        Haptic.impact(.light)
                    }
                }
            }
        }
    }

    // MARK: - CTA
    private var ctaSection: some View {
        VStack(spacing: 12) {
            Button {
                guard let product = selectedProduct else { return }
                Haptic.impact(.medium)
                Task { await subscriptionManager.purchase(product) }
            } label: {
                ZStack {
                    if subscriptionManager.isLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text(ctaTitle)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(
                    Capsule()
                        .fill(DesignSystem.Colors.primary)
                        .shadow(color: DesignSystem.Colors.primary.opacity(0.35), radius: 12, y: 6)
                )
            }
            .buttonStyle(SquishyButtonStyle())
            .disabled(subscriptionManager.isLoading || selectedProduct == nil)
            .opacity((subscriptionManager.isLoading || selectedProduct == nil) ? 0.6 : 1)

            Button {
                Task { await subscriptionManager.restorePurchases() }
            } label: {
                Text(L.paywall.restore)
                    .font(.system(size: 14))
                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.6))
                    .underline()
            }
            .disabled(subscriptionManager.isLoading)
        }
    }

    // MARK: - Features
    private var featuresSection: some View {
        VStack(spacing: 12) {
            ForEach(paywallFeatures, id: \.icon) { feature in
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(feature.color.opacity(0.15))
                            .frame(width: 40, height: 40)
                        Image(systemName: feature.icon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(feature.color)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feature.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                        Text(feature.description)
                            .font(.system(size: 13))
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.7))
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(DesignSystem.Colors.surfaceContainerLow)
                )
            }
        }
    }

    // MARK: - Footer
    private var footerSection: some View {
        VStack(spacing: 6) {
            Text(L.paywall.legalNote)
                .font(.system(size: 11))
                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.45))
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            HStack(spacing: 16) {
                Link(L.settings.privacyPolicy, destination: URL(string: "https://trident-kr.github.io/waitwhat-site/privacy")!)
                Link(L.settings.termsOfService, destination: URL(string: "https://trident-kr.github.io/waitwhat-site/terms")!)
            }
            .font(.system(size: 11))
            .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.45))
        }
    }

    // MARK: - Helpers
    private var ctaTitle: String {
        guard let product = selectedProduct else { return L.paywall.subscribe }
        return "\(L.paywall.startSubscription) · \(product.displayPrice)"
    }

    /// 연간 플랜 배지. 월간 대비 절약률을 실제 스토어 가격으로 계산하고,
    /// 두 상품이 모두 로드되지 않았거나 절약이 없으면 "BEST VALUE"로 폴백.
    private var yearlyBadgeText: String {
        let products = subscriptionManager.products
        guard let monthly = products.first(where: { $0.id == SubscriptionProductID.monthly.rawValue }),
              let yearly = products.first(where: { $0.id == SubscriptionProductID.yearly.rawValue }) else {
            return L.paywall.bestValue
        }
        let monthlyForYear = monthly.price * 12
        guard monthlyForYear > 0, yearly.price < monthlyForYear else { return L.paywall.bestValue }
        let ratio = (monthlyForYear - yearly.price) / monthlyForYear
        let percent = Int((NSDecimalNumber(decimal: ratio).doubleValue * 100).rounded())
        return percent > 0 ? L.paywall.savePercent(percent) : L.paywall.bestValue
    }

    /// 페이월에는 실제로 Pro 전용인 혜택(AI 입력 무제한)만 표시한다.
    /// 알람·위젯은 무료 플랜에서도 제공되므로 여기서 광고하지 않는다.
    private var paywallFeatures: [PaywallFeature] {
        [
            PaywallFeature(icon: "waveform", color: DesignSystem.Colors.primary, title: L.paywall.featureVoiceTitle, description: L.paywall.featureVoiceDesc),
            PaywallFeature(icon: "sparkles", color: DesignSystem.Colors.primary, title: L.paywall.featureAITitle,    description: L.paywall.featureAIDesc),
        ]
    }
}

// MARK: - Plan Card
private struct PlanCard: View {
    let product: Product
    let isSelected: Bool
    /// 카드 우측 상단 배지 문구. nil이면 배지를 그리지 않는다.
    let badgeText: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            isSelected ? DesignSystem.Colors.primary : DesignSystem.Colors.onSurfaceVariant.opacity(0.3),
                            lineWidth: isSelected ? 2.5 : 1.5
                        )
                        .frame(width: 22, height: 22)
                    if isSelected {
                        Circle()
                            .fill(DesignSystem.Colors.primary)
                            .frame(width: 12, height: 12)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(product.displayName.isEmpty ? planName : product.displayName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                        if let badgeText {
                            Text(badgeText)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(DesignSystem.Colors.primary))
                        }
                    }
                    Text(priceSubtitle)
                        .font(.system(size: 12))
                        .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.6))
                }

                Spacer()

                Text(product.displayPrice)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(isSelected ? DesignSystem.Colors.primary : DesignSystem.Colors.onSurfaceVariant)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(DesignSystem.Colors.surfaceContainerLow)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(
                                isSelected ? DesignSystem.Colors.primary : Color.clear,
                                lineWidth: 2
                            )
                    )
            )
        }
        .buttonStyle(SquishyButtonStyle())
    }

    private var planName: String {
        switch product.id {
        case SubscriptionProductID.monthly.rawValue: return L.paywall.planMonthly
        case SubscriptionProductID.yearly.rawValue:  return L.paywall.planYearly
        default: return product.id
        }
    }

    private var priceSubtitle: String {
        switch product.id {
        case SubscriptionProductID.monthly.rawValue:
            return L.paywall.billedMonthly
        case SubscriptionProductID.yearly.rawValue:
            // 스토어프론트 통화 그대로 월 환산 (예: $35.99/년 → $3.00/월, ₩49,000/년 → ₩4,083/월)
            let perMonth = (product.price / 12).formatted(product.priceFormatStyle)
            return L.paywall.billedYearly(perMonth: perMonth)
        default:
            return ""
        }
    }
}

// MARK: - Paywall Feature Model
private struct PaywallFeature {
    let icon: String
    let color: Color
    let title: String
    let description: String
}
