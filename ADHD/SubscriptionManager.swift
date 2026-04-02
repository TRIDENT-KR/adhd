import StoreKit
import Combine
import SwiftUI

// MARK: - Subscription Product IDs
enum SubscriptionProductID: String, CaseIterable {
    case monthly = "trident-KR.ADHD.premium.monthly"
    case yearly  = "trident-KR.ADHD.premium.yearly"
}

// MARK: - Subscription Manager
@MainActor
class SubscriptionManager: ObservableObject {
    @Published var isPremium: Bool = false
    @Published var products: [Product] = []
    @Published var purchaseError: String? = nil
    @Published var isLoading: Bool = false
    @Published var productsLoadFailed: Bool = false

    private var transactionListenerTask: Task<Void, Never>?

    init() {
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
