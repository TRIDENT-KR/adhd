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
        defaults.removeObject(forKey: Self.aiQuotaKey(for: userID))
    }

    // MARK: AI 횟수 표시용 마지막 서버 스냅샷
    /// 서버에 횟수만 묻는 API가 없어서, 다시 실행해도 마지막으로 받은 값을 보여 주려고 계정별로 기억합니다.
    /// 표시용일 뿐이며 실제 차감·차단은 서버가 판단합니다.
    static func aiQuotaKey(for userID: UUID) -> String {
        "mora.subscription.\(namespace(for: userID)).ai-quota.v1"
    }

    func aiQuota(for userID: UUID) -> CachedAIQuota? {
        guard let data = defaults.data(forKey: Self.aiQuotaKey(for: userID)) else { return nil }
        return try? JSONDecoder().decode(CachedAIQuota.self, from: data)
    }

    func save(aiQuota: CachedAIQuota, for userID: UUID) {
        guard let data = try? JSONEncoder().encode(aiQuota) else { return }
        defaults.set(data, forKey: Self.aiQuotaKey(for: userID))
    }
}

nonisolated struct CachedAIQuota: Codable, Equatable {
    let used: Int
    let remaining: Int?
    let usageDate: String
    let timeZone: String
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

    /// 배지에 보일 남은 횟수. 마지막 서버 값이 오늘(서울 기준) 것이 아니면 자정에 다시 찬 한도로 봅니다.
    static func displayedRemaining(
        remaining: Int?,
        usageDate: String?,
        timeZone: String?,
        limit: Int,
        now: Date
    ) -> Int {
        guard let remaining, let usageDate, timeZone == "Asia/Seoul",
              usageDate == serverDay(of: now) else { return limit }
        return max(0, min(limit, remaining))
    }

    private static func serverDay(of date: Date) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

// MARK: - Server Adapter
nonisolated enum SubscriptionServerError: Error, Equatable {
    case transactionRegistrationUnavailable
    case restoreRebindUnavailable
    case subscriptionOwnedByAnotherAccount
    case familySharingNotSupported
    case transactionRejected
    /// claim한 구독이 지금 유효하지 않음. 복원할 것이 없다는 뜻이라 조용히 넘깁니다.
    case claimNotActive
}

/// 현재 권리 거래를 이 계정에 어떻게 보낼지 고릅니다.
/// 이 계정 토큰으로 산 거래는 register, 이전(다른) 계정 토큰이나 토큰 없이 산 거래는 claim입니다.
/// 같은 Apple ID로 앱을 다시 설치하거나 다른 기기에서 열면 새 익명 계정이 claim으로 Pro를 이어받습니다.
nonisolated enum StoreKitSyncAction: String, Equatable {
    case register
    case claim

    static func choose(transactionToken: UUID?, accountToken: UUID) -> StoreKitSyncAction {
        transactionToken == accountToken ? .register : .claim
    }

    /// register가 거절됐을 때 같은 JWS로 다시 보낼 동작. 이 계정 토큰으로 산 거래라도
    /// 원래 구독이 이전 계정에 묶여 있으면(예: 이어받은 구독을 이 설치에서 업그레이드) 서버가
    /// subscription_owned_by_another_account(409)로 거절하므로 claim으로 다시 보냅니다.
    static func retry(afterRegisterFailure error: Error) -> StoreKitSyncAction? {
        (error as? SubscriptionServerError) == .subscriptionOwnedByAnotherAccount ? .claim : nil
    }
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
        case "claim_not_active":
            return .claimNotActive
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
}

@MainActor
protocol SubscriptionServerClient {
    var supportsTransactionRegistration: Bool { get }

    func fetchAppAccountToken(for operation: SubscriptionOperationContext) async throws -> UUID
    func fetchEntitlement(for operation: SubscriptionOperationContext) async throws -> ServerEntitlementSnapshot
    func registerVerifiedTransaction(jws: String, for operation: SubscriptionOperationContext) async throws
    func claimVerifiedTransaction(jws: String, for operation: SubscriptionOperationContext) async throws
}

/// 요청별 토큰을 고정해 SDK가 await 중 바뀐 다른 계정 세션으로 요청을 보내지 못하게 합니다.
struct SupabaseSubscriptionServerClient: SubscriptionServerClient {
    let supportsTransactionRegistration = true

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
        try await syncTransaction(action: .register, jws: jws, for: operation)
    }

    func claimVerifiedTransaction(jws: String, for operation: SubscriptionOperationContext) async throws {
        try await syncTransaction(action: .claim, jws: jws, for: operation)
    }

    private struct SyncResponse: Decodable {
        let result: String
    }

    private func syncTransaction(action: StoreKitSyncAction, jws: String, for operation: SubscriptionOperationContext) async throws {
        let options = FunctionInvokeOptions(
            body: ["action": action.rawValue, "signedTransaction": jws]
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
        // 계정이 아직 준비되지 않은 경우(SubscriptionFlowError.accountRequired)는 로그인 안내 없이
        // 아래 단계별 문구(결제 안 됨·복원 실패)로 보냅니다. 익명 계정이 붙으면 다시 누르면 됩니다.
        switch error {
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
        ServerQuotaAccessPolicy.displayedRemaining(
            remaining: serverQuotaRemaining,
            usageDate: serverQuotaUsageDate,
            timeZone: serverQuotaTimeZone,
            limit: Self.freeAILimit,
            now: now()
        )
    }

    /// 이 서버 계정의 구독 범위가 열려 있는지. 익명 계정을 막 만든 직후 결제 전에 확인합니다.
    func isActiveAccount(_ userID: UUID) -> Bool {
        activeUserID == userID
    }

    /// 자정이 지나거나 앱으로 돌아왔을 때 배지를 다시 계산하게 합니다(남은 횟수는 현재 시각에 따라 달라짐).
    func refreshQuotaDisplay() {
        objectWillChange.send()
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
        if let activeUserID {
            accountCache.save(
                aiQuota: CachedAIQuota(
                    used: snapshot.used,
                    remaining: snapshot.remaining,
                    usageDate: snapshot.usageDate,
                    timeZone: snapshot.timeZone
                ),
                for: activeUserID
            )
        }
    }

    /// 다시 실행했을 때 마지막 서버 스냅샷으로 배지를 채웁니다. 날짜가 지났으면 표시 단계에서 한도로 돌아갑니다.
    private func restoreCachedQuota(for userID: UUID) {
        guard let cached = accountCache.aiQuota(for: userID) else { return }
        dailyAIUsageCount = cached.used
        serverQuotaRemaining = cached.remaining
        serverQuotaUsageDate = cached.usageDate
        serverQuotaTimeZone = cached.timeZone
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
                try await registerFallingBackToClaim(jws: evidence.jws, for: context)
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

            // 사용자가 누른 복원은 claim 실패도 그대로 알려 줍니다(지금 유효하지 않은 구독만 조용히 건너뜀).
            let restoredTransactions = try await syncCurrentEntitlements(
                for: context, accountToken: appAccountToken, claims: .reportingFailures
            )

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
    /// claimsOtherAccountPurchases는 계정을 열 때(실행·익명 계정 생성·다시 연결)만 켭니다.
    /// 토큰 갱신 같은 잦은 이벤트에서는 이 계정 토큰 거래만 register합니다.
    func refreshPremiumStatus(claimsOtherAccountPurchases: Bool = false) async {
        guard let operation = try? currentOperation() else { return }
        let userID = operation.userID

        do {
            if server.supportsTransactionRegistration {
                // 이 경로의 claim 실패는 Pro 판정을 막지 않도록 넘기고, 아래 서버 entitlement가 최종 판단합니다.
                let appAccountToken = try await fetchStableAppAccountToken(for: operation)
                _ = try await syncCurrentEntitlements(
                    for: operation, accountToken: appAccountToken,
                    claims: claimsOtherAccountPurchases ? .quietly : .skipped
                )
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

    /// AuthManager가 확인한 서버 계정(익명 포함)으로 구독을 엽니다. 구독·캐시는 서버 계정(userID) 기준입니다.
    func activateLocalAccountScope(_ userID: UUID) {
        activateAccount(userID)
        applyCachedEntitlement(for: userID)
        Task { [weak self] in
            guard let self, self.activeUserID == userID else { return }
            await self.refreshPremiumStatus(claimsOtherAccountPurchases: true)
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
        restoreCachedQuota(for: userID)
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
            try await registerFallingBackToClaim(jws: evidence.jws, for: operation)
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

    /// 다른(이전) 계정 토큰으로 산 거래를 어떻게 다룰지
    private enum ClaimHandling {
        /// claim하지 않고 건너뜀 (토큰 갱신 같은 잦은 갱신)
        case skipped
        /// claim하고 실패는 넘김 (계정을 열 때)
        case quietly
        /// claim하고 실패를 알림 (사용자가 누른 구매 복원)
        case reportingFailures
    }

    /// 검증된 현재 권리 거래를 이 계정에 보냅니다. 이 계정 토큰이면 register, 아니면 claim입니다.
    /// 이 계정에 보낸 거래만 돌려줍니다. 지금 유효하지 않은 구독(claim_not_active)은 복원할 것이 없으므로 건너뜁니다.
    private func syncCurrentEntitlements(
        for operation: SubscriptionOperationContext,
        accountToken: UUID,
        claims: ClaimHandling
    ) async throws -> [Transaction] {
        var synced: [Transaction] = []
        for await verification in Transaction.currentEntitlements {
            try ensureCurrentOperation(operation)
            guard case .verified(let transaction) = verification,
                  SubscriptionProductID.allIDs.contains(transaction.productID),
                  transaction.ownershipType == .purchased,
                  transaction.revocationDate == nil else { continue }

            let jws = verification.jwsRepresentation
            var action = StoreKitSyncAction.choose(transactionToken: transaction.appAccountToken, accountToken: accountToken)
            if action == .register {
                do {
                    try await server.registerVerifiedTransaction(jws: jws, for: operation)
                } catch {
                    guard let retry = StoreKitSyncAction.retry(afterRegisterFailure: error) else { throw error }
                    try ensureCurrentOperation(operation)
                    action = retry
                }
            }
            if action == .claim {
                guard claims != .skipped,
                      try await claim(jws: jws, for: operation, reportingFailures: claims == .reportingFailures) else { continue }
            }
            synced.append(transaction)
        }
        return synced
    }

    /// claim을 보내고 이 계정에 묶였는지 돌려줍니다.
    /// 지금 유효한 구독이 아니면(claim_not_active: 만료, 또는 StoreKit이 아직 이전 기간 거래를 들고 있는 경우)
    /// 복원할 것이 없다는 뜻이라 조용히 false입니다. 다음 갱신 때 다시 claim합니다.
    private func claim(jws: String, for operation: SubscriptionOperationContext, reportingFailures: Bool) async throws -> Bool {
        do {
            try await server.claimVerifiedTransaction(jws: jws, for: operation)
            return true
        } catch SubscriptionServerError.claimNotActive {
            return false
        } catch {
            try ensureCurrentOperation(operation)
            if reportingFailures { throw error }
            print("storekit_claim_failed")
            return false
        }
    }

    /// 결제 직후·거래 업데이트용 register. 다른 계정 소유로 거절되면 같은 JWS를 claim으로 다시 보냅니다.
    private func registerFallingBackToClaim(jws: String, for operation: SubscriptionOperationContext) async throws {
        do {
            try await server.registerVerifiedTransaction(jws: jws, for: operation)
        } catch {
            guard StoreKitSyncAction.retry(afterRegisterFailure: error) == .claim else { throw error }
            try ensureCurrentOperation(operation)
            try await server.claimVerifiedTransaction(jws: jws, for: operation)
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
            publishPremium(true)
        } else {
            accountCache.clearEntitlement(for: userID)
            publishPremium(false)
        }
    }

    /// 서버 일시 장애 동안 마지막 서버 확인(24시간 이내)을 믿고 Pro를 유지합니다. 유지하지 못하면 false.
    private func keepCachedEntitlementDuringOutage(for userID: UUID) -> Bool {
        guard let cached = accountCache.entitlement(for: userID),
              SubscriptionAccessPolicy.allowsProDuringServerOutage(
                cached,
                confirmedAt: accountCache.serverConfirmedAt(for: userID),
                at: now()
              ) else { return false }
        publishPremium(true)
        return true
    }

    private func applyCachedEntitlement(for userID: UUID) {
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
