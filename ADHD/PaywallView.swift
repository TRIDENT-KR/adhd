import SwiftUI
import StoreKit

// MARK: - Paywall View
struct PaywallView: View {
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject private var authManager: AuthManager
    @Environment(\.dismiss) private var dismiss

    /// nil이면 기본 선택(연간, 없으면 남은 상품)을 씁니다.
    @State private var selectedProductID: String?
    @State private var showError: Bool = false
    /// 익명 계정을 붙이는 동안 버튼을 한 번만 누르게 합니다.
    @State private var isPreparingAccount = false

    /// 상품이 하나만 불러와져도 화면에 보이는 선택과 실제 결제 상품이 같도록 여기서 정합니다.
    private var selectedProduct: Product? {
        let products = subscriptionManager.products
        if let selected = products.first(where: { $0.id == selectedProductID }) { return selected }
        let fallbackID = SubscriptionProductCatalog.defaultSelection(in: products.map(\.id))
        return products.first { $0.id == fallbackID }
    }

    private var errorTitle: String {
        subscriptionManager.purchaseErrorAction == .restore
            ? L.paywall.restoreErrorTitle
            : L.paywall.purchaseErrorTitle
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

                    if subscriptionManager.isPremium {
                        activeSubscriptionSection
                            .padding(.top, 28)
                    } else {
                        planSection
                            .padding(.top, 28)

                        ctaSection
                            .padding(.top, 24)
                    }

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
                    .disabled(subscriptionManager.isLoading)
            }
        }
        // 결제 직후 서버 등록 중에 닫으면 등록 오류를 보여 줄 곳이 없어집니다.
        .interactiveDismissDisabled(subscriptionManager.isLoading)
        .alert(errorTitle, isPresented: $showError) {
            Button(L.paywall.ok, role: .cancel) { subscriptionManager.purchaseError = nil }
        } message: {
            Text(subscriptionManager.purchaseError ?? "")
        }
        .onChange(of: subscriptionManager.purchaseError) { _, error in
            showError = error != nil
        }
        // 확인하지 못한 오류가 남아 있으면 다시 열 때 보여 줍니다.
        .onAppear {
            if subscriptionManager.purchaseError != nil { showError = true }
        }
        .task {
            // 일부 상품만 받아온 경우에도 빠진 상품을 한 번 더 불러 봅니다.
            if subscriptionManager.products.count < SubscriptionProductID.allCases.count {
                await subscriptionManager.loadProducts()
            }
        }
    }

    /// 로그인은 없습니다. 보이지 않는 익명 계정이 아직 없으면 한 번 만들어 보고,
    /// 앱 루트가 새 계정의 구독 범위를 열 때까지 잠깐(최대 2초) 기다립니다.
    /// 그래도 준비되지 않으면 구매·복원이 '결제는 시작되지 않았어요'/'복원하지 못했어요'로 알려 줍니다.
    private func prepareAccount() async {
        guard await authManager.provisionAnonymousAccountIfNeeded(),
              let accountID = authManager.accessState.accountUserID else { return }
        var waited = 0
        while !subscriptionManager.isActiveAccount(accountID), waited < 20 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
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
            .accessibilityHidden(true)

            Text(L.paywall.title)
                .font(.system(.title, design: .rounded, weight: .bold))
                .foregroundColor(DesignSystem.Colors.primary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text(L.paywall.subtitle)
                .font(DesignSystem.Typography.bodyMd)
                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
    }

    // MARK: - Plan Selection
    private var planSection: some View {
        VStack(spacing: 10) {
            Text(L.paywall.choosePlan)
                .font(.footnote.weight(.semibold))
                .foregroundColor(DesignSystem.Colors.onSurfaceMeta)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)

            if subscriptionManager.products.isEmpty {
                if subscriptionManager.productsLoadFailed {
                    VStack(spacing: 4) {
                        Text(L.paywall.loadPlansFailed)
                            .font(DesignSystem.Typography.labelSm)
                            .foregroundColor(DesignSystem.Colors.onSurfaceMeta)
                        Button {
                            Task { await subscriptionManager.loadProducts() }
                        } label: {
                            Text(L.paywall.retry)
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(DesignSystem.Colors.primary)
                                .frame(minWidth: 44, minHeight: 44)
                                .padding(.horizontal, 12)
                                .contentShape(Rectangle())
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
                            .foregroundColor(DesignSystem.Colors.onSurfaceMeta)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            } else {
                ForEach(subscriptionManager.products, id: \.id) { product in
                    PlanCard(
                        product: product,
                        isSelected: selectedProduct?.id == product.id,
                        badgeText: savingsBadge(for: product)
                    ) {
                        selectedProductID = product.id
                        Haptic.impact(.light)
                    }
                }
            }
        }
    }

    private var activeSubscriptionSection: some View {
        VStack(spacing: 16) {
            Label(L.paywall.premiumActive, systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(DesignSystem.Colors.tertiary)
            Button(L.settings.done) { dismiss() }
                .font(.headline)
                .foregroundStyle(DesignSystem.Colors.primary)
            Link(L.paywall.manageSubscription, destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity)
    }

    private var isBusy: Bool {
        subscriptionManager.isLoading || isPreparingAccount
    }

    private var purchaseButtonDisabled: Bool {
        isBusy || selectedProduct == nil
    }

    // MARK: - CTA
    private var ctaSection: some View {
        VStack(spacing: 12) {
            Button {
                guard let product = selectedProduct else { return }
                Haptic.impact(.medium)
                isPreparingAccount = true
                Task {
                    await prepareAccount()
                    isPreparingAccount = false
                    if await subscriptionManager.purchase(product) { dismiss() }
                }
            } label: {
                ZStack {
                    if isBusy {
                        ProgressView()
                            .tint(DesignSystem.Colors.onPrimary)
                    } else {
                        Text(ctaTitle)
                            .font(.headline)
                            .foregroundColor(DesignSystem.Colors.onPrimary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .frame(minHeight: 54)
                .background(
                    Capsule()
                        .fill(DesignSystem.Colors.primary)
                        .shadow(color: DesignSystem.Colors.primary.opacity(0.35), radius: 12, y: 6)
                )
            }
            .buttonStyle(SquishyButtonStyle())
            .disabled(purchaseButtonDisabled)
            .opacity(purchaseButtonDisabled ? 0.6 : 1)

            Button {
                isPreparingAccount = true
                Task {
                    await prepareAccount()
                    isPreparingAccount = false
                    if await subscriptionManager.restorePurchases() { dismiss() }
                }
            } label: {
                Text(L.paywall.restore)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                    .underline()
                    .frame(minHeight: 44)
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
            }
            .disabled(isBusy)

            if let notice = subscriptionManager.purchaseNotice {
                Text(notice)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.updatesFrequently)
            }
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
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feature.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                        Text(feature.description)
                            .font(.footnote)
                            .foregroundColor(DesignSystem.Colors.onSurfaceMeta)
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
                .font(.footnote)
                .foregroundColor(DesignSystem.Colors.onSurfaceMeta)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                Link(L.settings.privacyPolicy, destination: URL(string: "https://trident-kr.github.io/waitwhat-site/privacy/")!)
                Link(L.settings.termsOfService, destination: URL(string: "https://trident-kr.github.io/waitwhat-site/terms/")!)
            }
            .font(.footnote.weight(.semibold))
            .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
            .frame(minHeight: 44)
        }
    }

    // MARK: - Helpers
    private var ctaTitle: String {
        guard let product = selectedProduct else { return L.paywall.subscribe }
        return "\(L.paywall.startSubscription) · \(product.displayPrice)"
    }

    private func savingsBadge(for product: Product) -> String? {
        guard product.id == SubscriptionProductID.yearly.rawValue,
              let monthly = subscriptionManager.products.first(where: {
                  $0.id == SubscriptionProductID.monthly.rawValue
              }),
              let percent = SubscriptionPricing.annualSavingsPercent(
                  monthly: monthly.price, yearly: product.price,
                  monthlyCurrency: monthly.priceFormatStyle.currencyCode,
                  yearlyCurrency: product.priceFormatStyle.currencyCode
              ) else { return nil }
        return L.paywall.savePercent(percent)
    }

    /// Pro에서만 달라지는 것만 적습니다. AI 분류 자체는 무료(하루 3회)에도 있어서 따로 혜택으로 넣지 않습니다
    /// (무료와 Pro의 AI 차이는 첫 항목의 횟수 제한뿐 — 심사 지침 3.1.2).
    private var paywallFeatures: [PaywallFeature] {
        [
            PaywallFeature(icon: "waveform",        color: DesignSystem.Colors.primary,          title: L.paywall.featureVoiceTitle,   description: L.paywall.featureVoiceDesc),
            PaywallFeature(icon: "alarm",           color: DesignSystem.Colors.tertiary,         title: L.paywall.featureAlarmsTitle,  description: L.paywall.featureAlarmsDesc),
            PaywallFeature(icon: "apps.iphone",     color: DesignSystem.Colors.tertiary,         title: L.paywall.featureWidgetsTitle, description: L.paywall.featureWidgetsDesc),
        ]
    }
}

// MARK: - Plan Card
private struct PlanCard: View {
    let product: Product
    let isSelected: Bool
    let badgeText: String?
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 큰 글자에서는 배지를 플랜 이름 아래로 내려 이름이 글자 단위로 끊기지 않게 합니다.
    private var nameLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 8))
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            isSelected ? DesignSystem.Colors.primary : DesignSystem.Colors.outline,
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
                    nameLayout {
                        Text(planName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                        if let badgeText {
                            Text(badgeText)
                                .font(.caption2.weight(.bold))
                                .foregroundColor(DesignSystem.Colors.onPrimary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(DesignSystem.Colors.primary))
                        }
                    }
                    Text(priceSubtitle)
                        .font(.caption)
                        .foregroundColor(DesignSystem.Colors.onSurfaceMeta)
                }

                Spacer()

                Text(product.displayPrice)
                    .font(.callout.weight(.bold))
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
        // 선택은 원과 테두리 색으로만 보이므로 VoiceOver에는 선택 상태와 한 줄 라벨로 알려 줍니다.
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var accessibilityLabel: String {
        L.paywall.planAccessibilityLabel(
            name: planName, price: product.displayPrice, period: billingPeriod, badge: badgeText
        )
    }

    private var billingPeriod: String {
        switch product.id {
        case SubscriptionProductID.yearly.rawValue: return L.paywall.billedAnnually
        default: return L.paywall.billedMonthly
        }
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
        case SubscriptionProductID.monthly.rawValue: return L.paywall.billedMonthly
        case SubscriptionProductID.yearly.rawValue:
            let monthlyEquivalent = (product.price / 12).formatted(
                product.priceFormatStyle
            )
            return L.paywall.billedYearly(monthlyEquivalent: monthlyEquivalent)
        default: return ""
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

/// Compare regular prices from the same storefront without overstating rounded savings.
enum SubscriptionPricing {
    static func annualSavingsPercent(
        monthly: Decimal, yearly: Decimal,
        monthlyCurrency: String, yearlyCurrency: String
    ) -> Int? {
        guard monthlyCurrency == yearlyCurrency, !monthlyCurrency.isEmpty,
              monthly > 0, yearly > 0, yearly < monthly * 12 else { return nil }
        var value = (1 - yearly / (monthly * 12)) * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .down)
        let percent = NSDecimalNumber(decimal: rounded).intValue
        return (1...99).contains(percent) ? percent : nil
    }
}
