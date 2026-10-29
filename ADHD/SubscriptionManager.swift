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

/// App Store가 갱신 결제를 다시 시도하는 중인 상태 (설정 화면 안내용)
nonisolated enum SubscriptionBillingIssue: Equatable {
    /// 결제 실패, 유예 기간이라 Pro는 아직 켜져 있음
    case gracePeriod
    /// 결제 실패, 유예 기간이 지나 Pro가 멈춤 (결제 수단을 바꾸면 복구)
    case paused

    init?(status: SubscriptionEntitlementStatus) {
        switch status {
        case .grace: self = .gracePeriod
        case .billingRetry: self = .paused
        case .none, .active, .expired, .revoked, .refunded: return nil
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

    /// 서버 일시 장애 동안 마지막 서버 확인을 믿는 최대 시간 (제품 결정, 2026-10-28)
    static let serverOutageGrace: TimeInterval = 24 * 60 * 60

    /// 서버가 5xx로 응답하지 못할 때: 마지막 서버 확인이 24시간 안이고 구독 기간도 남아 있으면 Pro를 유지합니다.
    static func allowsProDuringServerOutage(
        _ cached: CachedSubscriptionEntitlement,
        confirmedAt: Date?,
        at now: Date
    ) -> Bool {
        guard let confirmedAt,
              confirmedAt <= now.addingTimeInterval(60),           // 기기 시계가 크게 뒤로 간 경우 거부
              now.timeIntervalSince(confirmedAt) <= serverOutageGrace else { return false }
        return allowsOfflinePro(cached, at: now)
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

    static func serverConfirmedKey(for userID: UUID) -> String {
        "mora.subscription.\(namespace(for: userID)).server-confirmed-at.v1"
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
        defaults.removeObject(forKey: Self.serverConfirmedKey(for: userID))
    }

    /// 서버가 Pro를 마지막으로 확인한 시각 (서버 일시 장애 때 유지 기간 계산용)
    func markServerConfirmed(for userID: UUID, at date: Date) {
        defaults.set(date, forKey: Self.serverConfirmedKey(for: userID))
    }

    func serverConfirmedAt(for userID: UUID) -> Date? {
        defaults.object(forKey: Self.serverConfirmedKey(for: userID)) as? Date
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

    /// 서버가 잠깐 응답하지 못한 경우(HTTP 5xx, 예: subscription_backend_unavailable 503).
    /// '이 사용자는 Pro가 아니다'라는 확정 응답이 아니므로 마지막 서버 확인을 잠시 믿습니다.
    static func isTransientServerFailure(_ error: Error) -> Bool {
        if case let FunctionsError.httpError(code, _) = error { return code >= 500 }
        if let httpError = error as? HTTPError { return httpError.response.statusCode >= 500 }
        return false
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
nonisolated enum SubscriptionServerError: Error, Equatable {
    case transactionRegistrationUnavailable
    case restoreRebindUnavailable
    case subscriptionOwnedByAnotherAccount
    case familySharingNotSupported
    case transactionRejected
}

/// storekit-sync의 `{ "error": { "code": ... } }` 응답을 앱 오류로 옮깁니다.
/// 목록에 없는 코드는 nil을 돌려 일시 장애로 취급합니다.
nonisolated enum StoreKitSyncErrorMapper {
    private struct Envelope: Decodable {
        struct Body: Decodable { let code: String }
        let error: Body
    }

    static func map(status: Int, data: Data) -> SubscriptionServerError? {
        guard let code = try? JSONDecoder().decode(Envelope.self, from: data).error.code else {
            return nil
        }
        switch code {
        case "subscription_owned_by_another_account":
            return .subscriptionOwnedByAnotherAccount
        case "rebind_not_eligible":
            return .restoreRebindUnavailable
        case "family_sharing_not_supported":
            return .familySharingNotSupported
        default:
            // 422는 Apple 서명·상품·형식 검증 실패라 재시도해도 결과가 같습니다.
            return status == 422 ? .transactionRejected : nil
        }
    }
}

/// 계정이 한 번이라도 닫히면 이전 작업은 같은 계정으로 재로그인해도 재사용하지 않습니다.
nonisolated struct SubscriptionOperationContext: Sendable {
    let userID: UUID
    let generation: UUID
    let accessToken: String
}

nonisolated struct SubscriptionOperationScope {
    private(set) var userID: UUID?
    private var generation = UUID()

    mutating func activate(_ userID: UUID) {
        guard self.userID != userID else { return }
        self.userID = userID
        generation = UUID()
    }

    mutating func deactivate() {
        userID = nil
        generation = UUID()
    }

    func capture(sessionUserID: UUID, accessToken: String) -> SubscriptionOperationContext? {
        guard userID == sessionUserID, !accessToken.isEmpty else { return nil }
        return SubscriptionOperationContext(userID: sessionUserID, generation: generation, accessToken: accessToken)
    }

    func accepts(_ operation: SubscriptionOperationContext, sessionUserID: UUID?) -> Bool {
        userID == operation.userID
            && sessionUserID == operation.userID
            && generation == operation.generation
    }

    /// Closing a management-only restore must not close a newer account or a newly eligible session.
    mutating func finishRestrictedManagementOperation(
        _ operation: SubscriptionOperationContext,
        sessionUserID: UUID?,
        isLocallyEligible: Bool
    ) -> Bool {
        guard accepts(operation, sessionUserID: sessionUserID), !isLocallyEligible else { return false }
        deactivate()
        return true
    }
}

@MainActor
protocol SubscriptionServerClient {
    var supportsTransactionRegistration: Bool { get }
    var supportsRestoreRebind: Bool { get }

    func fetchAppAccountToken(for operation: SubscriptionOperationContext) async throws -> UUID
    func fetchEntitlement(for operation: SubscriptionOperationContext) async throws -> ServerEntitlementSnapshot
    func registerVerifiedTransaction(jws: String, for operation: SubscriptionOperationContext) async throws
    func claimSubscriptionRebind(jws: String, for operation: SubscriptionOperationContext) async throws
}

/// 요청별 토큰을 고정해 SDK가 await 중 바뀐 다른 계정 세션으로 요청을 보내지 못하게 합니다.
struct SupabaseSubscriptionServerClient: SubscriptionServerClient {
    let supportsTransactionRegistration = true
    let supportsRestoreRebind = true

    private func client(for operation: SubscriptionOperationContext) -> SupabaseClient {
        SupabaseConfig.requestClient(accessToken: operation.accessToken)
    }

    func fetchAppAccountToken(for operation: SubscriptionOperationContext) async throws -> UUID {
        let response: PostgrestResponse<UUID> = try await client(for: operation)
            .rpc("mora_get_app_account_token")
            .execute()
        return response.value
    }

    func fetchEntitlement(for operation: SubscriptionOperationContext) async throws -> ServerEntitlementSnapshot {
        let response: PostgrestResponse<ServerEntitlementSnapshot> = try await client(for: operation)
            .rpc("mora_get_entitlement")
            .execute()
        return response.value
    }

    func registerVerifiedTransaction(jws: String, for operation: SubscriptionOperationContext) async throws {
        try await syncTransaction(action: "register", jws: jws, for: operation)
    }

    func claimSubscriptionRebind(jws: String, for operation: SubscriptionOperationContext) async throws {
        try await syncTransaction(action: "rebind", jws: jws, for: operation)
    }

    private struct SyncResponse: Decodable {
        let result: String
    }

    private func syncTransaction(action: String, jws: String, for operation: SubscriptionOperationContext) async throws {
        let options = FunctionInvokeOptions(
            body: ["action": action, "signedTransaction": jws]
        )
        do {
            let _: SyncResponse = try await client(for: operation).functions.invoke("storekit-sync", options: options)
        } catch let FunctionsError.httpError(code, data) {
            throw StoreKitSyncErrorMapper.map(status: code, data: data)
                ?? FunctionsError.httpError(code: code, data: data)
        }
    }
}

nonisolated enum SubscriptionFlowError: Error {
    case accountRequired
    case productContractMismatch
    case transactionRegistrationUnavailable
    case invalidTransaction
    case appAccountTokenChanged
    case entitlementNotGranted
    case nothingToRestore
}

// MARK: - Product Catalog
nonisolated enum SubscriptionProductCatalog {
    /// 받아온 상품 중 알려진 것만 월간→연간 순서로 남깁니다. 하나가 빠져도 나머지는 팔 수 있어야 합니다.
    static func validProducts<Item>(_ items: [Item], id: (Item) -> String) -> [Item] {
        let order = SubscriptionProductID.allCases.map(\.rawValue)
        var seen = Set<String>()
        return items
            .filter { order.contains(id($0)) && seen.insert(id($0)).inserted }
            .sorted { order.firstIndex(of: id($0))! < order.firstIndex(of: id($1))! }
    }

    /// 기본 선택은 연간이고, 연간이 없으면 남아 있는 상품입니다.
    static func defaultSelection(in availableIDs: [String]) -> String? {
        availableIDs.contains(SubscriptionProductID.yearly.rawValue)
            ? SubscriptionProductID.yearly.rawValue
            : availableIDs.first
    }
}

// MARK: - Error Copy
/// 실패가 어느 단계에서 났는지. 결제 시트 전 실패에 '다시 결제하기 전에 복원' 안내를 붙이지 않기 위해 씁니다.
nonisolated enum SubscriptionFlowStage: Equatable {
    /// StoreKit 결제 시트 전: 계정 토큰 조회, 성인 확인
    case preparing
    /// StoreKit 결제 시트
    case paying
    /// 결제 후 서버 등록·권한 확인
    case registering
    /// 사용자가 누른 구매 복원
    case restoring
}

enum SubscriptionErrorCopy: Equatable {
    case accountRequired
    case eligibility(AdultEligibilityError)
    case paymentNotStarted
    case registrationUnavailable
    case restoreRebindUnavailable
    case ownedByAnotherAccount
    case familySharingUnsupported
    case verificationFailed
    case nothingToRestore
    case accountTokenChanged
    case entitlementNotGranted
    /// 결제 후 확인 실패: 다시 결제하기 전에 복원을 권합니다.
    case serverUnavailable
    case restoreFailed

    static func classify(_ error: Error, stage: SubscriptionFlowStage) -> SubscriptionErrorCopy {
        if let eligibilityError = error as? AdultEligibilityError {
            // 성인 확인 서버가 응답하지 않은 것은 결제 전 일시 장애입니다.
            return eligibilityError == .unavailable ? .paymentNotStarted : .eligibility(eligibilityError)
        }
        switch error {
        case SubscriptionFlowError.accountRequired:
            return .accountRequired
        case SubscriptionFlowError.transactionRegistrationUnavailable:
            return .registrationUnavailable
        case SubscriptionFlowError.appAccountTokenChanged:
            return .accountTokenChanged
        case SubscriptionFlowError.nothingToRestore:
            return .nothingToRestore
        case SubscriptionServerError.restoreRebindUnavailable:
            return .restoreRebindUnavailable
        case SubscriptionServerError.subscriptionOwnedByAnotherAccount:
            return .ownedByAnotherAccount
        case SubscriptionServerError.familySharingNotSupported:
            return .familySharingUnsupported
        default:
            break
        }

        switch stage {
        case .preparing:
            return .paymentNotStarted
        case .paying:
            // 시트가 확실히 결제 전에 끝난 경우만 '결제 안 됨'이라고 말합니다. 네트워크 오류는 결제됐을 수도 있습니다.
            if error is Product.PurchaseError { return .paymentNotStarted }
            if let storeKitError = error as? StoreKitError {
                switch storeKitError {
                case .notAvailableInStorefront, .notEntitled, .unsupported:
                    return .paymentNotStarted
                default:
                    return .serverUnavailable
                }
            }
            return .serverUnavailable
        case .registering:
            switch error {
            case SubscriptionServerError.transactionRejected,
                 SubscriptionFlowError.productContractMismatch,
                 SubscriptionFlowError.invalidTransaction:
                return .verificationFailed
            case SubscriptionFlowError.entitlementNotGranted:
                return .entitlementNotGranted
            default:
                return .serverUnavailable
            }
        case .restoring:
            switch error {
            case SubscriptionServerError.transactionRejected:
                return .verificationFailed
            default:
                return .restoreFailed
            }
        }
    }

    var message: String {
        switch self {
        case .accountRequired: return L.paywall.accountRequired
        case .eligibility(let error): return L.adultEligibility.error(error)
        case .paymentNotStarted: return L.paywall.paymentNotStarted
        case .registrationUnavailable: return L.paywall.registrationUnavailable
        case .restoreRebindUnavailable: return L.paywall.restoreRebindUnavailable
        case .ownedByAnotherAccount: return L.paywall.ownedByAnotherAccount
        case .familySharingUnsupported: return L.paywall.familySharingUnsupported
        case .verificationFailed: return L.paywall.verificationFailed
        case .nothingToRestore: return L.paywall.nothingToRestore
        case .accountTokenChanged: return L.paywall.accountTokenChanged
        case .entitlementNotGranted: return L.paywall.entitlementNotGranted
        case .serverUnavailable: return L.paywall.serverUnavailable
        case .restoreFailed: return L.paywall.restoreFailed
        }
    }
}

/// 오류 알림 제목을 고르기 위한 마지막 실패 작업
enum SubscriptionUserAction: Equatable {
    case purchase
    case restore
}

// MARK: - Subscription Manager
@MainActor
final class SubscriptionManager: ObservableObject {
    @Published private(set) var isPremium = false
    @Published private(set) var products: [Product] = []
    @Published var purchaseError: String?
    /// purchaseError가 구매와 복원 중 어디서 났는지. 알림 제목을 고릅니다.
    @Published private(set) var purchaseErrorAction: SubscriptionUserAction = .purchase
    @Published private(set) var purchaseNotice: String?
    @Published private(set) var isLoading = false
    @Published private(set) var productsLoadFailed = false
    /// 결제가 밀려 App Store가 재시도 중이면 설정에 안내합니다. 말없이 무료로 바뀌지 않게 합니다.
    @Published private(set) var billingIssue: SubscriptionBillingIssue?

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
    private var operationScope = SubscriptionOperationScope()
    private var activeUserID: UUID? { operationScope.userID }
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
            let fetched = try await Product.products(for: SubscriptionProductID.allCases.map(\.rawValue))
            let valid = SubscriptionProductCatalog.validProducts(fetched, id: \.id)
            // 받아온 상품만이라도 보여주고, 하나도 없을 때만 실패로 봅니다.
            guard !valid.isEmpty else {
                products = []
                productsLoadFailed = true
                print("storekit_products_empty")
                return
            }
            if valid.count < SubscriptionProductID.allCases.count {
                print("storekit_products_partial")
            }
            products = valid
        } catch {
            // 다시 불러오다 실패해도 이미 보여 준 상품은 그대로 둡니다.
            productsLoadFailed = products.isEmpty
            print("storekit_products_load_failed")
        }
    }

    // MARK: - Purchase
    @discardableResult
    func purchase(_ product: Product) async -> Bool {
        guard !isLoading else { return false }
        isLoading = true
        purchaseError = nil
        purchaseNotice = nil
        defer { isLoading = false }
        var operation: SubscriptionOperationContext?
        var stage = SubscriptionFlowStage.preparing

        do {
            guard SubscriptionProductID.allIDs.contains(product.id) else {
                throw SubscriptionFlowError.productContractMismatch
            }
            guard server.supportsTransactionRegistration else {
                // 서버 전달이 불가능한 상태에서 먼저 과금하지 않습니다.
                throw SubscriptionFlowError.transactionRegistrationUnavailable
            }

            let context = try currentOperation()
            operation = context
            let userID = context.userID
            let appAccountToken = try await fetchStableAppAccountToken(for: context)
            try await AdultEligibilityManager.shared.requireServerEligibility(
                userID: userID, accessToken: context.accessToken
            )
            try ensureCurrentOperation(context)
            stage = .paying
            let result = try await product.purchase(options: [
                .appAccountToken(appAccountToken)
            ])

            stage = .registering
            try ensureCurrentOperation(context)
            switch result {
            case .success(let verification):
                let evidence = try verifiedEvidence(
                    verification,
                    expectedProductID: product.id,
                    expectedToken: appAccountToken
                )
                try ensureCurrentOperation(context)
                try await server.registerVerifiedTransaction(jws: evidence.jws, for: context)
                try ensureCurrentOperation(context)
                let entitlement = try await server.fetchEntitlement(for: context)
                try ensureCurrentOperation(context)
                applyServerEntitlement(entitlement, for: userID)
                guard SubscriptionAccessPolicy.allowsServerPro(entitlement, at: now()) else {
                    throw SubscriptionFlowError.entitlementNotGranted
                }
                await evidence.transaction.finish()
                try ensureCurrentOperation(context)
                return SubscriptionAccessPolicy.allowsServerPro(entitlement, at: now())
            case .userCancelled:
                return false
            case .pending:
                purchaseNotice = L.paywall.purchasePending
                return false
            @unknown default:
                throw SubscriptionFlowError.invalidTransaction
            }
        } catch StoreKitError.userCancelled {
            return false
        } catch {
            if let operation, !isCurrentOperation(operation) { return false }
            reportError(error, stage: stage, action: .purchase)
            return false
        }
    }

    // MARK: - Explicit Restore
    /// 제한 화면에서도 이미 구입한 권리를 복원합니다. 일반 앱/위젯 범위는 열지 않습니다.
    @discardableResult
    func restorePurchasesForAccountManagement(userID: UUID) async -> Bool {
        guard !isLoading else { return false }
        guard (try? currentAuthenticatedUserID()) == userID else {
            reportError(SubscriptionFlowError.accountRequired, stage: .restoring, action: .restore)
            return false
        }
        operationScope.activate(userID)
        guard let operation = try? currentOperation() else {
            reportError(SubscriptionFlowError.accountRequired, stage: .restoring, action: .restore)
            return false
        }
        let restored = await restorePurchases()
        // A newly eligible/current account may have entered the normal app while restore was pending.
        let currentSessionUserID = try? currentAuthenticatedUserID()
        let isLocallyEligible = AdultEligibilityManager.shared.allowsLocalUse(for: userID)
        let shouldClose = operationScope.finishRestrictedManagementOperation(
            operation,
            sessionUserID: currentSessionUserID,
            isLocallyEligible: isLocallyEligible
        )
        if shouldClose {
            publishPremium(false, removeSharedFlag: true)
        }
        return restored
    }

    @discardableResult
    func restorePurchases() async -> Bool {
        guard !isLoading else { return false }
        isLoading = true
        purchaseError = nil
        purchaseNotice = nil
        defer { isLoading = false }
        var operation: SubscriptionOperationContext?

        do {
            guard server.supportsTransactionRegistration else {
                throw SubscriptionFlowError.transactionRegistrationUnavailable
            }

            let context = try currentOperation()
            operation = context
            let userID = context.userID
            let appAccountToken = try await fetchStableAppAccountToken(for: context)
            try await AppStore.sync()
            try ensureCurrentOperation(context)

            var restoredTransactions: [Transaction] = []
            for await verification in Transaction.currentEntitlements {
                guard case .verified(let transaction) = verification,
                      SubscriptionProductID.allIDs.contains(transaction.productID),
                      transaction.ownershipType == .purchased,
                      transaction.revocationDate == nil else { continue }

                try ensureCurrentOperation(context)
                if transaction.appAccountToken == appAccountToken {
                    try await server.registerVerifiedTransaction(jws: verification.jwsRepresentation, for: context)
                } else {
                    // 자동 이전은 금지합니다. 이 경로는 사용자가 Restore를 누른 경우에만 실행됩니다.
                    guard server.supportsRestoreRebind else {
                        throw SubscriptionServerError.restoreRebindUnavailable
                    }
                    try await server.claimSubscriptionRebind(jws: verification.jwsRepresentation, for: context)
                }
                restoredTransactions.append(transaction)
            }

            guard !restoredTransactions.isEmpty else {
                throw SubscriptionFlowError.nothingToRestore
            }
            try ensureCurrentOperation(context)
            let entitlement = try await server.fetchEntitlement(for: context)
            try ensureCurrentOperation(context)
            applyServerEntitlement(entitlement, for: userID)
            guard SubscriptionAccessPolicy.allowsServerPro(entitlement, at: now()) else {
                throw SubscriptionFlowError.entitlementNotGranted
            }
            for transaction in restoredTransactions {
                await transaction.finish()
            }
            try ensureCurrentOperation(context)
            return SubscriptionAccessPolicy.allowsServerPro(entitlement, at: now())
        } catch StoreKitError.userCancelled {
            return false
        } catch {
            if let operation, !isCurrentOperation(operation) { return false }
            reportError(error, stage: .restoring, action: .restore)
            return false
        }
    }

    // MARK: - Server Entitlement Refresh
    func refreshPremiumStatus() async {
        guard let operation = try? currentOperation() else { return }
        let userID = operation.userID

        do {
            if server.supportsTransactionRegistration {
                try await registerMatchingCurrentEntitlements(for: operation)
            }
            try ensureCurrentOperation(operation)
            let entitlement = try await server.fetchEntitlement(for: operation)
            try ensureCurrentOperation(operation)
            applyServerEntitlement(entitlement, for: userID)
        } catch {
            guard isCurrentOperation(operation) else { return }
            if SubscriptionFailureClassifier.permitsOfflineCache(error) {
                applyCachedEntitlement(for: userID)
            } else if SubscriptionFailureClassifier.isTransientServerFailure(error),
                      keepCachedEntitlementDuringOutage(for: userID) {
                // 서버 일시 장애(5xx): 결제한 사용자의 Pro를 바로 끄지 않고 다음 갱신 때 다시 확인합니다.
                print("server_entitlement_refresh_deferred_outage")
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
            deactivateAccount(clearCache: false)
        }
    }

    /// AuthManager가 검증한 로컬 범위만 구독 계정을 열 수 있습니다.
    func activateLocalAccountScope(_ userID: UUID) {
        guard AdultEligibilityManager.shared.allowsLocalUse(for: userID) else {
            activateGuestScope()
            return
        }
        activateAccount(userID)
        applyCachedEntitlement(for: userID)
        Task { [weak self] in
            guard let self, self.activeUserID == userID else { return }
            await self.refreshPremiumStatus()
        }
    }

    /// 게스트는 기존 계정 캐시를 지우지 않지만 Pro·quota 상태를 공유하지 않습니다.
    func activateGuestScope() {
        deactivateAccount(clearCache: false)
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
        // 지연된 provider 이벤트가 게스트/다른 계정으로 바뀐 로컬 범위를 다시 열지 않습니다.
        guard activeUserID == userID,
              (try? currentAuthenticatedUserID()) == userID else { return }
        await refreshPremiumStatus()
    }

    private func handleSignedOutAccount() {
        // 이미 새 계정이 로그인한 뒤 도착한 이전 signedOut 이벤트는 무시합니다.
        guard supabase.auth.currentSession == nil else { return }
        deactivateAccount(clearCache: true)
    }

    private func activateAccount(_ userID: UUID) {
        guard activeUserID != userID else { return }
        if let previousUserID = activeUserID {
            accountCache.clearAccount(previousUserID)
        }
        operationScope.activate(userID)
        purchaseError = nil
        purchaseNotice = nil
        billingIssue = nil
        resetQuotaMirror()
        publishPremium(false, removeSharedFlag: true)
        applyCachedEntitlement(for: userID)
    }

    private func deactivateAccount(clearCache: Bool) {
        if clearCache, let activeUserID {
            accountCache.clearAccount(activeUserID)
        }
        operationScope.deactivate()
        purchaseError = nil
        purchaseNotice = nil
        billingIssue = nil
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
              let operation = try? currentOperation(),
              let appAccountToken = try? await fetchStableAppAccountToken(for: operation),
              let evidence = try? verifiedEvidence(
                verification,
                expectedProductID: nil,
                expectedToken: appAccountToken
              ) else { return }

        do {
            try ensureCurrentOperation(operation)
            try await server.registerVerifiedTransaction(jws: evidence.jws, for: operation)
            try ensureCurrentOperation(operation)
            let entitlement = try await server.fetchEntitlement(for: operation)
            try ensureCurrentOperation(operation)
            applyServerEntitlement(entitlement, for: operation.userID)
            await evidence.transaction.finish()
        } catch {
            // 서버 전달이 성공하기 전에는 finish하지 않아 다음 업데이트에서 재시도할 수 있게 합니다.
            print("storekit_transaction_sync_failed")
        }
    }

    private func registerMatchingCurrentEntitlements(for operation: SubscriptionOperationContext) async throws {
        let appAccountToken = try await fetchStableAppAccountToken(for: operation)
        for await verification in Transaction.currentEntitlements {
            try ensureCurrentOperation(operation)
            guard let evidence = try? verifiedEvidence(
                verification,
                expectedProductID: nil,
                expectedToken: appAccountToken
            ) else { continue }
            try await server.registerVerifiedTransaction(jws: evidence.jws, for: operation)
        }
    }

    // MARK: - Cache and Publication
    private func fetchStableAppAccountToken(for operation: SubscriptionOperationContext) async throws -> UUID {
        try ensureCurrentOperation(operation)
        let token = try await server.fetchAppAccountToken(for: operation)
        try ensureCurrentOperation(operation)
        do {
            try accountCache.accept(appAccountToken: token, for: operation.userID)
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
        billingIssue = SubscriptionBillingIssue(status: entitlement.status)
        if let cached = SubscriptionAccessPolicy.cacheRecord(from: entitlement, at: now()) {
            accountCache.save(entitlement: cached, for: userID)
            accountCache.markServerConfirmed(for: userID, at: now())
            publishPremium(AdultEligibilityManager.shared.allowsLocalUse(for: userID))
        } else {
            accountCache.clearEntitlement(for: userID)
            publishPremium(false)
        }
    }

    /// 서버 일시 장애 동안 마지막 서버 확인(24시간 이내)을 믿고 Pro를 유지합니다. 유지하지 못하면 false.
    private func keepCachedEntitlementDuringOutage(for userID: UUID) -> Bool {
        guard AdultEligibilityManager.shared.allowsLocalUse(for: userID),
              let cached = accountCache.entitlement(for: userID),
              SubscriptionAccessPolicy.allowsProDuringServerOutage(
                cached,
                confirmedAt: accountCache.serverConfirmedAt(for: userID),
                at: now()
              ) else { return false }
        publishPremium(true)
        return true
    }

    private func applyCachedEntitlement(for userID: UUID) {
        guard AdultEligibilityManager.shared.allowsLocalUse(for: userID) else {
            publishPremium(false, removeSharedFlag: true)
            return
        }
        guard let cached = accountCache.entitlement(for: userID),
              SubscriptionAccessPolicy.allowsOfflinePro(cached, at: now()) else {
            accountCache.clearEntitlement(for: userID)
            publishPremium(false)
            return
        }
        billingIssue = SubscriptionBillingIssue(status: cached.status)
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

    private func currentOperation() throws -> SubscriptionOperationContext {
        guard let session = supabase.auth.currentSession, !session.isExpired,
              let operation = operationScope.capture(
                sessionUserID: session.user.id, accessToken: session.accessToken
              ) else {
            throw SubscriptionFlowError.accountRequired
        }
        return operation
    }

    private func isCurrentOperation(_ operation: SubscriptionOperationContext) -> Bool {
        operationScope.accepts(operation, sessionUserID: try? currentAuthenticatedUserID())
    }

    private func ensureCurrentOperation(_ operation: SubscriptionOperationContext) throws {
        guard isCurrentOperation(operation) else { throw SubscriptionFlowError.accountRequired }
    }

    private func currentAuthenticatedUserID() throws -> UUID {
        guard let session = supabase.auth.currentSession, !session.isExpired else {
            throw SubscriptionFlowError.accountRequired
        }
        return session.user.id
    }

    private func reportError(_ error: Error, stage: SubscriptionFlowStage, action: SubscriptionUserAction) {
        purchaseErrorAction = action
        purchaseError = SubscriptionErrorCopy.classify(error, stage: stage).message
    }
}
