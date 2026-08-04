import StoreKit
import Combine
import CryptoKit
import Foundation
import Supabase
import WidgetKit

// MARK: - Subscription Product IDs
nonisolated enum SubscriptionProductID: String, CaseIterable, Codable {
    case monthly = "com.TRIDENT.ADHD.monthly"
    case yearly = "com.TRIDENT.ADHD.yearly"

    static let allIDs = Set(allCases.map(\.rawValue))
}

// MARK: - Server Entitlement Contract
nonisolated enum SubscriptionEntitlementStatus: String, Codable {
    case none
    case active
    case grace
    case billingRetry = "billing_retry"
    case expired
    case revoked
    case refunded
}

/// `public.mora_get_entitlement()`의 엄격한 응답 모델입니다.
/// 알 수 없는 상태·상품·날짜 형식은 디코딩 단계에서 거부합니다.
nonisolated struct ServerEntitlementSnapshot: Decodable, Equatable {
    let isPro: Bool
    let status: SubscriptionEntitlementStatus
    let productID: String?
    let verifiedAt: Date?
    let expiresAt: Date?
    let graceExpiresAt: Date?
    let accessUntil: Date?

    private enum CodingKeys: String, CodingKey {
        case isPro
        case status
        case productID = "productId"
        case verifiedAt
        case expiresAt
        case graceExpiresAt
        case accessUntil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isPro = try container.decode(Bool.self, forKey: .isPro)
        status = try container.decode(SubscriptionEntitlementStatus.self, forKey: .status)
        productID = try container.decodeIfPresent(String.self, forKey: .productID)
        verifiedAt = try Self.decodeDate(.verifiedAt, from: container)
        expiresAt = try Self.decodeDate(.expiresAt, from: container)
        graceExpiresAt = try Self.decodeDate(.graceExpiresAt, from: container)
        accessUntil = try Self.decodeDate(.accessUntil, from: container)

        if let productID, !SubscriptionProductID.allIDs.contains(productID) {
            throw DecodingError.dataCorruptedError(
                forKey: .productID,
                in: container,
                debugDescription: "Unknown subscription product"
            )
        }
        guard Self.hasValidShape(
            isPro: isPro,
            status: status,
            productID: productID,
            verifiedAt: verifiedAt,
            expiresAt: expiresAt,
            graceExpiresAt: graceExpiresAt,
            accessUntil: accessUntil
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .status,
                in: container,
                debugDescription: "Inconsistent entitlement payload"
            )
        }
    }

    private static func decodeDate(
        _ key: CodingKeys,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Date? {
        guard let rawValue = try container.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: rawValue) {
            return date
        }

        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        guard let date = wholeSeconds.date(from: rawValue) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Invalid entitlement timestamp"
            )
        }
        return date
    }

    private static func hasValidShape(
        isPro: Bool,
        status: SubscriptionEntitlementStatus,
        productID: String?,
        verifiedAt: Date?,
        expiresAt: Date?,
        graceExpiresAt: Date?,
        accessUntil: Date?
    ) -> Bool {
        if isPro && status != .active && status != .grace {
            return false
        }

        switch status {
        case .active:
            return productID != nil
                && verifiedAt != nil
                && expiresAt != nil
                && accessUntil != nil
        case .grace:
            return productID != nil
                && verifiedAt != nil
                && expiresAt != nil
                && graceExpiresAt != nil
                && accessUntil != nil
        case .none, .billingRetry, .expired, .revoked, .refunded:
            return !isPro
        }
    }
}

nonisolated struct CachedSubscriptionEntitlement: Codable, Equatable {
    let status: SubscriptionEntitlementStatus
    let productID: String
    let verifiedAt: Date
    let expiresAt: Date
    let graceExpiresAt: Date?
    let accessUntil: Date
}

/// 서버 상태와 오프라인 캐시 모두에 동일한 만료 규칙을 적용하는 순수 판정기입니다.
nonisolated enum SubscriptionAccessPolicy {
    static func allowsServerPro(_ snapshot: ServerEntitlementSnapshot, at now: Date) -> Bool {
        guard snapshot.isPro,
              let deadline = accessDeadline(
                status: snapshot.status,
                expiresAt: snapshot.expiresAt,
                graceExpiresAt: snapshot.graceExpiresAt,
                accessUntil: snapshot.accessUntil
              ) else { return false }
        return deadline > now
    }

    static func cacheRecord(
        from snapshot: ServerEntitlementSnapshot,
        at now: Date
    ) -> CachedSubscriptionEntitlement? {
        guard allowsServerPro(snapshot, at: now),
              let productID = snapshot.productID,
              let verifiedAt = snapshot.verifiedAt,
              let expiresAt = snapshot.expiresAt,
              let accessUntil = snapshot.accessUntil else { return nil }

        return CachedSubscriptionEntitlement(
            status: snapshot.status,
            productID: productID,
            verifiedAt: verifiedAt,
            expiresAt: expiresAt,
            graceExpiresAt: snapshot.graceExpiresAt,
            accessUntil: accessUntil
        )
    }

    static func allowsOfflinePro(
        _ cached: CachedSubscriptionEntitlement,
        at now: Date
    ) -> Bool {
        guard SubscriptionProductID.allIDs.contains(cached.productID),
              let deadline = accessDeadline(
                status: cached.status,
                expiresAt: cached.expiresAt,
                graceExpiresAt: cached.graceExpiresAt,
                accessUntil: cached.accessUntil
              ) else { return false }
        return deadline > now
    }

    private static func accessDeadline(
        status: SubscriptionEntitlementStatus,
        expiresAt: Date?,
        graceExpiresAt: Date?,
        accessUntil: Date?
    ) -> Date? {
        guard let accessUntil else { return nil }
        switch status {
        case .active:
            guard let expiresAt else { return nil }
            return min(accessUntil, expiresAt)
        case .grace:
            guard let graceExpiresAt else { return nil }
            return min(accessUntil, graceExpiresAt)
        case .none, .billingRetry, .expired, .revoked, .refunded:
            return nil
        }
    }
}

nonisolated enum SubscriptionCacheError: Error {
    case appAccountTokenChanged
}

nonisolated struct SubscriptionAccountCache {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func namespace(for userID: UUID) -> String {
        let normalizedID = userID.uuidString.lowercased()
        return SHA256.hash(data: Data(normalizedID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func entitlementKey(for userID: UUID) -> String {
        "mora.subscription.\(namespace(for: userID)).entitlement.v1"
    }

    static func appAccountTokenKey(for userID: UUID) -> String {
        "mora.subscription.\(namespace(for: userID)).app-account-token.v1"
    }

    func entitlement(for userID: UUID) -> CachedSubscriptionEntitlement? {
        guard let data = defaults.data(forKey: Self.entitlementKey(for: userID)) else {
            return nil
        }
        return try? JSONDecoder().decode(CachedSubscriptionEntitlement.self, from: data)
    }

    func save(entitlement: CachedSubscriptionEntitlement, for userID: UUID) {
        guard let data = try? JSONEncoder().encode(entitlement) else { return }
        defaults.set(data, forKey: Self.entitlementKey(for: userID))
    }

    func clearEntitlement(for userID: UUID) {
        defaults.removeObject(forKey: Self.entitlementKey(for: userID))
    }

    func appAccountToken(for userID: UUID) -> UUID? {
        guard let value = defaults.string(forKey: Self.appAccountTokenKey(for: userID)) else {
            return nil
        }
        return UUID(uuidString: value)
    }

    func accept(appAccountToken token: UUID, for userID: UUID) throws {
        if let cached = appAccountToken(for: userID), cached != token {
            throw SubscriptionCacheError.appAccountTokenChanged
        }
        defaults.set(
            token.uuidString.lowercased(),
            forKey: Self.appAccountTokenKey(for: userID)
        )
    }

    func clearAccount(_ userID: UUID) {
        clearEntitlement(for: userID)
        defaults.removeObject(forKey: Self.appAccountTokenKey(for: userID))
    }
}

nonisolated enum SubscriptionFailureClassifier {
    static func permitsOfflineCache(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        let code = URLError.Code(rawValue: nsError.code)
        return [
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .networkConnectionLost,
            .dnsLookupFailed,
            .notConnectedToInternet,
            .internationalRoamingOff,
            .callIsActive,
            .dataNotAllowed,
        ].contains(code)
    }
}

nonisolated enum ServerQuotaAccessPolicy {
    static func canAttemptAnalysis(
        remaining: Int?,
        usageDate: String?,
        timeZone: String?,
        now: Date
    ) -> Bool {
        guard let remaining,
              let usageDate,
              timeZone == "Asia/Seoul" else { return true }

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        guard let year = parts.year, let month = parts.month, let day = parts.day else {
            return true
        }
        let today = String(format: "%04d-%02d-%02d", year, month, day)
        return usageDate != today || remaining > 0
    }
}

// MARK: - Server Adapter
nonisolated enum SubscriptionServerError: Error {
    case transactionRegistrationUnavailable
    case restoreRebindUnavailable
    case subscriptionOwnedByAnotherAccount
}

@MainActor
protocol SubscriptionServerClient {
    var supportsTransactionRegistration: Bool { get }
    var supportsRestoreRebind: Bool { get }

    func fetchAppAccountToken() async throws -> UUID
    func fetchEntitlement() async throws -> ServerEntitlementSnapshot
    func registerVerifiedTransaction(jws: String) async throws
    func claimSubscriptionRebind(jws: String) async throws
}

/// 현재 migration에 존재하는 읽기 RPC만 연결합니다.
/// 거래 등록·재귀속은 Apple JWS를 서버에서 검증하는 endpoint가 추가될 때 활성화해야 합니다.
struct SupabaseSubscriptionServerClient: SubscriptionServerClient {
    let supportsTransactionRegistration = false
    let supportsRestoreRebind = false

    func fetchAppAccountToken() async throws -> UUID {
        let response: PostgrestResponse<UUID> = try await supabase
            .rpc("mora_get_app_account_token")
            .execute()
        return response.value
    }

    func fetchEntitlement() async throws -> ServerEntitlementSnapshot {
        let response: PostgrestResponse<ServerEntitlementSnapshot> = try await supabase
            .rpc("mora_get_entitlement")
            .execute()
        return response.value
    }

    func registerVerifiedTransaction(jws: String) async throws {
        throw SubscriptionServerError.transactionRegistrationUnavailable
    }

    func claimSubscriptionRebind(jws: String) async throws {
        throw SubscriptionServerError.restoreRebindUnavailable
    }
}

nonisolated private enum SubscriptionFlowError: Error {
    case accountRequired
    case productContractMismatch
    case transactionRegistrationUnavailable
    case invalidTransaction
    case appAccountTokenChanged
    case entitlementNotGranted
    case nothingToRestore
}

// MARK: - Subscription Manager
@MainActor
final class SubscriptionManager: ObservableObject {
    @Published private(set) var isPremium = false
    @Published private(set) var products: [Product] = []
    @Published var purchaseError: String?
    @Published private(set) var isLoading = false
    @Published private(set) var productsLoadFailed = false

    /// 서버 quota 응답의 표시용 mirror입니다. 로컬에서 증가·날짜 초기화하지 않습니다.
    @Published private(set) var dailyAIUsageCount = 0
    @Published private(set) var serverQuotaRemaining: Int?
    @Published private(set) var serverQuotaUsageDate: String?
    @Published private(set) var serverQuotaTimeZone: String?

    static let freeAILimit = 3

    /// 알림·알람·위젯 표시용 캐시. 권한 원천은 서버 entitlement입니다.
    static let premiumFlagKey = "isPremiumUser"

    private let server: any SubscriptionServerClient
    private let accountCache: SubscriptionAccountCache
    private let now: () -> Date
    private var activeUserID: UUID?
    private var transactionListenerTask: Task<Void, Never>?
    private var authListenerTask: Task<Void, Never>?

    var canUseAI: Bool {
        isPremium || ServerQuotaAccessPolicy.canAttemptAnalysis(
            remaining: serverQuotaRemaining,
            usageDate: serverQuotaUsageDate,
            timeZone: serverQuotaTimeZone,
            now: now()
        )
    }

    var remainingAIUsage: Int {
        max(0, serverQuotaRemaining ?? Self.freeAILimit)
    }

    convenience init() {
        self.init(
            server: SupabaseSubscriptionServerClient(),
            defaults: .standard,
            now: Date.init
        )
    }

    init(
        server: any SubscriptionServerClient,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.server = server
        self.accountCache = SubscriptionAccountCache(defaults: defaults)
        self.now = now
        self.activeUserID = supabase.auth.currentSession?.user.id

        if let activeUserID {
            applyCachedEntitlement(for: activeUserID)
        }

        transactionListenerTask = listenForTransactions()
        authListenerTask = listenForAuthChanges()
        Task { [weak self] in
            guard let self else { return }
            await self.loadProducts()
            await self.refreshPremiumStatus()
        }
    }

    deinit {
        transactionListenerTask?.cancel()
        authListenerTask?.cancel()
    }

    // MARK: - Server Quota Mirror
    func applyServerQuota(_ snapshot: ServerAIQuotaSnapshot) {
        guard snapshot.isValid else {
            print("server_quota_snapshot_rejected")
            return
        }
        dailyAIUsageCount = snapshot.used
        serverQuotaRemaining = snapshot.remaining
        serverQuotaUsageDate = snapshot.usageDate
        serverQuotaTimeZone = snapshot.timeZone
    }

    // MARK: - Products
    func loadProducts() async {
        productsLoadFailed = false
        do {
            let expectedIDs = SubscriptionProductID.allCases.map(\.rawValue)
            let fetched = try await Product.products(for: expectedIDs)
            guard Set(fetched.map(\.id)) == SubscriptionProductID.allIDs else {
                products = []
                productsLoadFailed = true
                print("storekit_product_contract_mismatch")
                return
            }
            products = fetched.sorted {
                expectedIDs.firstIndex(of: $0.id)! < expectedIDs.firstIndex(of: $1.id)!
            }
        } catch {
            products = []
            productsLoadFailed = true
            print("storekit_products_load_failed")
        }
    }

    // MARK: - Purchase
    func purchase(_ product: Product) async {
        isLoading = true
        purchaseError = nil
        defer { isLoading = false }

        do {
            guard SubscriptionProductID.allIDs.contains(product.id) else {
                throw SubscriptionFlowError.productContractMismatch
            }
            guard server.supportsTransactionRegistration else {
                // 서버 전달이 불가능한 상태에서 먼저 과금하지 않습니다.
                throw SubscriptionFlowError.transactionRegistrationUnavailable
            }

            let userID = try currentAuthenticatedUserID()
            let appAccountToken = try await fetchStableAppAccountToken(for: userID)
            let result = try await product.purchase(options: [
                .appAccountToken(appAccountToken)
            ])

            switch result {
            case .success(let verification):
                let evidence = try verifiedEvidence(
                    verification,
                    expectedProductID: product.id,
                    expectedToken: appAccountToken
                )
                try await server.registerVerifiedTransaction(jws: evidence.jws)
                let entitlement = try await server.fetchEntitlement()
                applyServerEntitlement(entitlement, for: userID)
                await evidence.transaction.finish()
                guard isPremium else {
                    throw SubscriptionFlowError.entitlementNotGranted
                }
            case .userCancelled, .pending:
                break
            @unknown default:
                throw SubscriptionFlowError.invalidTransaction
            }
        } catch {
            purchaseError = message(for: error)
        }
    }

    // MARK: - Explicit Restore
    func restorePurchases() async {
        isLoading = true
        purchaseError = nil
        defer { isLoading = false }

        do {
            guard server.supportsTransactionRegistration else {
                throw SubscriptionFlowError.transactionRegistrationUnavailable
            }

            let userID = try currentAuthenticatedUserID()
            let appAccountToken = try await fetchStableAppAccountToken(for: userID)
            try await AppStore.sync()

            var restoredTransactions: [Transaction] = []
            for await verification in Transaction.currentEntitlements {
                guard case .verified(let transaction) = verification,
                      SubscriptionProductID.allIDs.contains(transaction.productID),
                      transaction.ownershipType == .purchased,
                      transaction.revocationDate == nil else { continue }

                if transaction.appAccountToken == appAccountToken {
                    try await server.registerVerifiedTransaction(jws: verification.jwsRepresentation)
                } else {
                    // 자동 이전은 금지합니다. 이 경로는 사용자가 Restore를 누른 경우에만 실행됩니다.
                    guard server.supportsRestoreRebind else {
                        throw SubscriptionServerError.restoreRebindUnavailable
                    }
                    try await server.claimSubscriptionRebind(jws: verification.jwsRepresentation)
                }
                restoredTransactions.append(transaction)
            }

            guard !restoredTransactions.isEmpty else {
                throw SubscriptionFlowError.nothingToRestore
            }
            let entitlement = try await server.fetchEntitlement()
            applyServerEntitlement(entitlement, for: userID)
            for transaction in restoredTransactions {
                await transaction.finish()
            }
            guard isPremium else {
                throw SubscriptionFlowError.entitlementNotGranted
            }
        } catch {
            purchaseError = message(for: error)
        }
    }

    // MARK: - Server Entitlement Refresh
    func refreshPremiumStatus() async {
        guard let userID = try? currentAuthenticatedUserID() else {
            deactivateAccount(clearCache: true)
            return
        }
        activateAccount(userID)

        do {
            if server.supportsTransactionRegistration {
                try await registerMatchingCurrentEntitlements(for: userID)
            }
            let entitlement = try await server.fetchEntitlement()
            guard activeUserID == userID else { return }
            applyServerEntitlement(entitlement, for: userID)
        } catch {
            guard activeUserID == userID else { return }
            if SubscriptionFailureClassifier.permitsOfflineCache(error) {
                applyCachedEntitlement(for: userID)
            } else {
                accountCache.clearEntitlement(for: userID)
                publishPremium(false)
                print("server_entitlement_refresh_failed_closed")
            }
        }
    }

    /// 로그아웃·계정 삭제 정리기가 명시적으로 호출할 수 있는 계정 범위 API입니다.
    func clearAccountCache(for userID: UUID) {
        accountCache.clearAccount(userID)
        if activeUserID == userID {
            activeUserID = nil
            resetQuotaMirror()
            publishPremium(false, removeSharedFlag: true)
        }
    }

    /// 인증 계정 범위가 열릴 때 서버 호출 없이 해당 계정 캐시만 위젯/알림에 다시 결합합니다.
    func activateLocalAccountScope(_ userID: UUID) {
        activateAccount(userID)
        applyCachedEntitlement(for: userID)
    }

    // MARK: - Account Lifecycle
    private func listenForAuthChanges() -> Task<Void, Never> {
        Task { [weak self] in
            for await change in supabase.auth.authStateChanges {
                guard let self else { return }
                switch change.event {
                case .initialSession, .signedIn, .tokenRefreshed, .userUpdated:
                    if let session = change.session, !session.isExpired {
                        await self.handleAuthenticatedAccount(session.user.id)
                    }
                case .signedOut, .userDeleted:
                    self.handleSignedOutAccount()
                case .passwordRecovery, .mfaChallengeVerified:
                    break
                }
            }
        }
    }

    private func handleAuthenticatedAccount(_ userID: UUID) async {
        activateAccount(userID)
        await refreshPremiumStatus()
    }

    private func handleSignedOutAccount() {
        deactivateAccount(clearCache: true)
    }

    private func activateAccount(_ userID: UUID) {
        guard activeUserID != userID else { return }
        if let previousUserID = activeUserID {
            accountCache.clearAccount(previousUserID)
        }
        activeUserID = userID
        resetQuotaMirror()
        publishPremium(false, removeSharedFlag: true)
        applyCachedEntitlement(for: userID)
    }

    private func deactivateAccount(clearCache: Bool) {
        if clearCache, let activeUserID {
            accountCache.clearAccount(activeUserID)
        }
        activeUserID = nil
        resetQuotaMirror()
        publishPremium(false, removeSharedFlag: true)
    }

    private func resetQuotaMirror() {
        dailyAIUsageCount = 0
        serverQuotaRemaining = nil
        serverQuotaUsageDate = nil
        serverQuotaTimeZone = nil
    }

    // MARK: - Transaction Listener
    private func listenForTransactions() -> Task<Void, Never> {
        Task(priority: .background) { [weak self] in
            for await verification in Transaction.updates {
                guard let self else { return }
                await self.handleTransactionUpdate(verification)
            }
        }
    }

    private func handleTransactionUpdate(_ verification: VerificationResult<Transaction>) async {
        guard server.supportsTransactionRegistration,
              let userID = try? currentAuthenticatedUserID(),
              let appAccountToken = try? await fetchStableAppAccountToken(for: userID),
              let evidence = try? verifiedEvidence(
                verification,
                expectedProductID: nil,
                expectedToken: appAccountToken
              ) else { return }

        do {
            try await server.registerVerifiedTransaction(jws: evidence.jws)
            let entitlement = try await server.fetchEntitlement()
            guard activeUserID == userID else { return }
            applyServerEntitlement(entitlement, for: userID)
            await evidence.transaction.finish()
        } catch {
            // 서버 전달이 성공하기 전에는 finish하지 않아 다음 업데이트에서 재시도할 수 있게 합니다.
            print("storekit_transaction_sync_failed")
        }
    }

    private func registerMatchingCurrentEntitlements(for userID: UUID) async throws {
        let appAccountToken = try await fetchStableAppAccountToken(for: userID)
        for await verification in Transaction.currentEntitlements {
            guard let evidence = try? verifiedEvidence(
                verification,
                expectedProductID: nil,
                expectedToken: appAccountToken
            ) else { continue }
            try await server.registerVerifiedTransaction(jws: evidence.jws)
        }
    }

    // MARK: - Cache and Publication
    private func fetchStableAppAccountToken(for userID: UUID) async throws -> UUID {
        let token = try await server.fetchAppAccountToken()
        guard activeUserID == userID,
              supabase.auth.currentSession?.user.id == userID else {
            throw SubscriptionFlowError.accountRequired
        }
        do {
            try accountCache.accept(appAccountToken: token, for: userID)
        } catch SubscriptionCacheError.appAccountTokenChanged {
            throw SubscriptionFlowError.appAccountTokenChanged
        }
        return token
    }

    private func applyServerEntitlement(
        _ entitlement: ServerEntitlementSnapshot,
        for userID: UUID
    ) {
        guard activeUserID == userID else { return }
        if let cached = SubscriptionAccessPolicy.cacheRecord(from: entitlement, at: now()) {
            accountCache.save(entitlement: cached, for: userID)
            publishPremium(true)
        } else {
            accountCache.clearEntitlement(for: userID)
            publishPremium(false)
        }
    }

    private func applyCachedEntitlement(for userID: UUID) {
        guard let cached = accountCache.entitlement(for: userID),
              SubscriptionAccessPolicy.allowsOfflinePro(cached, at: now()) else {
            accountCache.clearEntitlement(for: userID)
            publishPremium(false)
            return
        }
        publishPremium(true)
    }

    private func publishPremium(_ value: Bool, removeSharedFlag: Bool = false) {
        let stateChanged = isPremium != value
        isPremium = value

        let defaults = UserDefaults(suiteName: appGroupID)
        let previousSharedValue = defaults?.object(forKey: Self.premiumFlagKey) as? Bool
        let previousSharedScope = defaults?.string(
            forKey: WidgetAccountScope.premiumScopeKey
        )
        let activeScope = AccountPreferences.activeScope
        if removeSharedFlag || activeScope == nil {
            defaults?.removeObject(forKey: Self.premiumFlagKey)
            defaults?.removeObject(forKey: WidgetAccountScope.premiumScopeKey)
        } else if let activeScope {
            defaults?.set(value, forKey: Self.premiumFlagKey)
            defaults?.set(activeScope, forKey: WidgetAccountScope.premiumScopeKey)
        }

        let sharedValueChanged = removeSharedFlag
            ? previousSharedValue != nil || previousSharedScope != nil
            : previousSharedValue != value || previousSharedScope != activeScope
        guard stateChanged || sharedValueChanged else { return }
        NotificationCenter.default.post(name: .premiumStatusChanged, object: nil)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Strict StoreKit Evidence
    private func verifiedEvidence(
        _ verification: VerificationResult<Transaction>,
        expectedProductID: String?,
        expectedToken: UUID
    ) throws -> (transaction: Transaction, jws: String) {
        guard case .verified(let transaction) = verification,
              SubscriptionProductID.allIDs.contains(transaction.productID),
              expectedProductID == nil || transaction.productID == expectedProductID,
              transaction.appAccountToken == expectedToken,
              transaction.ownershipType == .purchased,
              transaction.revocationDate == nil else {
            throw SubscriptionFlowError.invalidTransaction
        }
        return (transaction, verification.jwsRepresentation)
    }

    private func currentAuthenticatedUserID() throws -> UUID {
        guard let session = supabase.auth.currentSession, !session.isExpired else {
            throw SubscriptionFlowError.accountRequired
        }
        return session.user.id
    }

    private func message(for error: Error) -> String {
        switch error {
        case SubscriptionFlowError.accountRequired:
            return "Apple로 로그인한 뒤 다시 시도해 주세요."
        case SubscriptionFlowError.transactionRegistrationUnavailable,
             SubscriptionServerError.transactionRegistrationUnavailable:
            return "안전한 구독 확인 서버가 아직 준비되지 않았습니다. 결제는 진행되지 않았습니다."
        case SubscriptionServerError.restoreRebindUnavailable:
            return "이 구독을 현재 계정으로 복원할 수 없습니다. 지원팀에 문의해 주세요."
        case SubscriptionServerError.subscriptionOwnedByAnotherAccount:
            return "이 구독은 다른 Mora 계정에 연결되어 있습니다. 지원팀에 문의해 주세요."
        case SubscriptionFlowError.nothingToRestore:
            return "복원할 수 있는 구독을 찾지 못했습니다."
        case SubscriptionFlowError.appAccountTokenChanged:
            return "계정의 구독 식별자가 일치하지 않습니다. 지원팀에 문의해 주세요."
        case SubscriptionFlowError.entitlementNotGranted:
            return "결제 확인은 완료됐지만 구독 권한을 확인할 수 없습니다. 지원팀에 문의해 주세요."
        case SubscriptionFlowError.productContractMismatch,
             SubscriptionFlowError.invalidTransaction:
            return "구독 정보를 안전하게 확인할 수 없습니다. 잠시 후 다시 시도해 주세요."
        default:
            return "구독 서버에 연결할 수 없습니다. 잠시 후 다시 시도해 주세요."
        }
    }
}
