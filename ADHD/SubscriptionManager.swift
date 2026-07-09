import StoreKit
import Combine
import SwiftUI
import WidgetKit

// MARK: - Subscription Product IDs
enum SubscriptionProductID: String, CaseIterable {
    case monthly = "com.TRIDENT.ADHD.monthly"
    case yearly  = "com.TRIDENT.ADHD.yearly"
}

// MARK: - Subscription Manager
@MainActor
class SubscriptionManager: ObservableObject {
    @Published var isPremium: Bool = false
    @Published var products: [Product] = []
    @Published var purchaseError: String? = nil
    @Published var isLoading: Bool = false
    @Published var productsLoadFailed: Bool = false
    @Published var dailyAIUsageCount: Int = 0

    static let freeAILimit = 3
    private static let aiUsageCountKey = "dailyAIUsageCount"
    private static let aiUsageDateKey = "dailyAIUsageDate"

    /// D13/D14: 알림·알람 게이팅용 Pro 플래그 (App Group — 델리게이트/알람 스케줄러가 읽음)
    static let premiumFlagKey = "isPremiumUser"

    private var transactionListenerTask: Task<Void, Never>?

    var canUseAI: Bool {
        isPremium || dailyAIUsageCount < Self.freeAILimit
    }

    var remainingAIUsage: Int {
        max(0, Self.freeAILimit - dailyAIUsageCount)
    }

    func incrementAIUsage() {
        resetDailyCountIfNeeded()
        dailyAIUsageCount += 1
        UserDefaults.standard.set(dailyAIUsageCount, forKey: Self.aiUsageCountKey)
    }

    private func resetDailyCountIfNeeded() {
        let today = Calendar.current.startOfDay(for: Date())
        let storedDate = UserDefaults.standard.object(forKey: Self.aiUsageDateKey) as? Date ?? .distantPast
        if Calendar.current.startOfDay(for: storedDate) < today {
            dailyAIUsageCount = 0
            UserDefaults.standard.set(0, forKey: Self.aiUsageCountKey)
            UserDefaults.standard.set(today, forKey: Self.aiUsageDateKey)
        }
    }

    init() {
        // 일일 사용량 복원
        let today = Calendar.current.startOfDay(for: Date())
        let storedDate = UserDefaults.standard.object(forKey: Self.aiUsageDateKey) as? Date ?? .distantPast
        if Calendar.current.startOfDay(for: storedDate) < today {
            dailyAIUsageCount = 0
            UserDefaults.standard.set(0, forKey: Self.aiUsageCountKey)
            UserDefaults.standard.set(today, forKey: Self.aiUsageDateKey)
        } else {
            dailyAIUsageCount = UserDefaults.standard.integer(forKey: Self.aiUsageCountKey)
        }

        transactionListenerTask = listenForTransactions()
        Task {
            await loadProducts()
            await refreshPremiumStatus()
        }
    }

    deinit {
        transactionListenerTask?.cancel()
    }

    // MARK: - Load Products
    func loadProducts() async {
        productsLoadFailed = false
        do {
            let ids = SubscriptionProductID.allCases.map(\.rawValue)
            let fetched = try await Product.products(for: ids)
            products = fetched.sorted { lhs, rhs in
                let order = SubscriptionProductID.allCases.map(\.rawValue)
                let li = order.firstIndex(of: lhs.id) ?? 0
                let ri = order.firstIndex(of: rhs.id) ?? 0
                return li < ri
            }
            if products.isEmpty {
                productsLoadFailed = true
            }
        } catch {
            print("⚠️ StoreKit products 로드 실패: \(error)")
            productsLoadFailed = true
        }
    }

    // MARK: - Purchase
    func purchase(_ product: Product) async {
        isLoading = true
        purchaseError = nil
        defer { isLoading = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                await refreshPremiumStatus()
            case .userCancelled:
                break
            case .pending:
                break
            @unknown default:
                break
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    // MARK: - Restore
    func restorePurchases() async {
        isLoading = true
        purchaseError = nil
        defer { isLoading = false }

        do {
            try await AppStore.sync()
            await refreshPremiumStatus()
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    // MARK: - Refresh Status
    func refreshPremiumStatus() async {
        var hasPremium = false
        for await result in Transaction.currentEntitlements {
            if let transaction = try? checkVerified(result),
               SubscriptionProductID.allCases.map(\.rawValue).contains(transaction.productID) {
                hasPremium = true
                break
            }
        }
        isPremium = hasPremium

        // App Group에 플래그 공유 — 값이 바뀌었을 때만 기록·브로드캐스트
        // (strong 알람 백엔드 이관 트리거: AlarmKit ↔ UN)
        let defaults = UserDefaults(suiteName: appGroupID)
        let previous = defaults?.bool(forKey: Self.premiumFlagKey) ?? false
        if previous != hasPremium {
            defaults?.set(hasPremium, forKey: Self.premiumFlagKey)
            NotificationCenter.default.post(name: .premiumStatusChanged, object: nil)
            // D13: 위젯 잠금↔해제 즉시 전환 — 값이 바뀔 때만 리로드 (위젯 예산 보호)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: - Transaction Listener
    private func listenForTransactions() -> Task<Void, Never> {
        Task(priority: .background) {
            for await result in Transaction.updates {
                if let transaction = try? checkVerified(result) {
                    await transaction.finish()
                    await refreshPremiumStatus()
                }
            }
        }
    }

    // MARK: - Verify
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value): return value
        case .unverified(_, let error): throw error
        }
    }
}
