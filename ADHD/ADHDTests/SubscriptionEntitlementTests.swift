import Foundation
import Testing
@testable import ADHD

struct SubscriptionEntitlementTests {
    private let decoder = JSONDecoder()

    @Test func activeEntitlementStopsAtEarlierExpiryBoundary() throws {
        let snapshot = try decode("""
        {
          "isPro": true,
          "status": "active",
          "productId": "com.TRIDENT.ADHD.monthly",
          "verifiedAt": "2026-08-01T00:00:00.000Z",
          "expiresAt": "2026-09-01T00:00:00.000Z",
          "graceExpiresAt": null,
          "accessUntil": "2026-10-01T00:00:00.000Z"
        }
        """)

        #expect(SubscriptionAccessPolicy.allowsServerPro(
            snapshot,
            at: date("2026-08-31T23:59:59Z")
        ))
        #expect(!SubscriptionAccessPolicy.allowsServerPro(
            snapshot,
            at: date("2026-09-01T00:00:00Z")
        ))
    }

    @Test func explicitGraceRemainsProOnlyUntilGraceBoundary() throws {
        let snapshot = try decode("""
        {
          "isPro": true,
          "status": "grace",
          "productId": "com.TRIDENT.ADHD.yearly",
          "verifiedAt": "2026-08-01T00:00:00Z",
          "expiresAt": "2026-08-02T00:00:00Z",
          "graceExpiresAt": "2026-08-16T00:00:00Z",
          "accessUntil": "2026-08-20T00:00:00Z"
        }
        """)

        #expect(SubscriptionAccessPolicy.allowsServerPro(
            snapshot,
            at: date("2026-08-15T23:59:59Z")
        ))
        #expect(!SubscriptionAccessPolicy.allowsServerPro(
            snapshot,
            at: date("2026-08-16T00:00:00Z")
        ))
    }

    @Test func billingRetryWithoutGraceIsAlwaysFree() throws {
        let snapshot = try decode("""
        {
          "isPro": false,
          "status": "billing_retry",
          "productId": "com.TRIDENT.ADHD.monthly",
          "verifiedAt": "2026-08-01T00:00:00Z",
          "expiresAt": "2026-09-01T00:00:00Z",
          "graceExpiresAt": null,
          "accessUntil": "2026-09-01T00:00:00Z"
        }
        """)

        #expect(!SubscriptionAccessPolicy.allowsServerPro(
            snapshot,
            at: date("2026-08-02T00:00:00Z")
        ))
    }

    @Test func unknownStatusCannotDecode() {
        let json = """
        {
          "isPro": true,
          "status": "trial",
          "productId": "com.TRIDENT.ADHD.monthly",
          "verifiedAt": "2026-08-01T00:00:00Z",
          "expiresAt": "2026-09-01T00:00:00Z",
          "graceExpiresAt": null,
          "accessUntil": "2026-09-01T00:00:00Z"
        }
        """

        #expect(decodingFails(json))
    }

    @Test func unknownProductCannotDecode() {
        let json = """
        {
          "isPro": true,
          "status": "active",
          "productId": "com.example.untrusted",
          "verifiedAt": "2026-08-01T00:00:00Z",
          "expiresAt": "2026-09-01T00:00:00Z",
          "graceExpiresAt": null,
          "accessUntil": "2026-09-01T00:00:00Z"
        }
        """

        #expect(decodingFails(json))
    }

    @Test func nonProStatusCannotClaimProInPayload() {
        let json = """
        {
          "isPro": true,
          "status": "billing_retry",
          "productId": "com.TRIDENT.ADHD.monthly",
          "verifiedAt": "2026-08-01T00:00:00Z",
          "expiresAt": "2026-09-01T00:00:00Z",
          "graceExpiresAt": null,
          "accessUntil": "2026-09-01T00:00:00Z"
        }
        """

        #expect(decodingFails(json))
    }

    @Test func malformedTimestampCannotDecode() {
        let json = """
        {
          "isPro": true,
          "status": "active",
          "productId": "com.TRIDENT.ADHD.monthly",
          "verifiedAt": "not-a-date",
          "expiresAt": "2026-09-01T00:00:00Z",
          "graceExpiresAt": null,
          "accessUntil": "2026-09-01T00:00:00Z"
        }
        """

        #expect(decodingFails(json))
    }

    @Test func offlineCacheNeverOutlivesServerDeadline() throws {
        let snapshot = try decode("""
        {
          "isPro": true,
          "status": "active",
          "productId": "com.TRIDENT.ADHD.monthly",
          "verifiedAt": "2026-08-01T00:00:00Z",
          "expiresAt": "2026-08-10T00:00:00Z",
          "graceExpiresAt": null,
          "accessUntil": "2026-08-12T00:00:00Z"
        }
        """)
        let cached = SubscriptionAccessPolicy.cacheRecord(
            from: snapshot,
            at: date("2026-08-09T00:00:00Z")
        )

        #expect(cached != nil)
        if let cached {
            #expect(!SubscriptionAccessPolicy.allowsOfflinePro(
                cached,
                at: date("2026-08-10T00:00:00Z")
            ))
        }
    }

    @Test func accountCacheKeysAndTokensAreIsolated() throws {
        let suiteName = "SubscriptionEntitlementTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let cache = SubscriptionAccountCache(defaults: defaults)
        let firstUser = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondUser = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let firstToken = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!

        #expect(SubscriptionAccountCache.namespace(for: firstUser)
            == "7ac1b8d7010bb6cd3a3e84e7f90136b880bbc899e428ece49333372911ab9052")
        #expect(SubscriptionAccountCache.entitlementKey(for: firstUser)
            != SubscriptionAccountCache.entitlementKey(for: secondUser))
        #expect(!SubscriptionAccountCache.entitlementKey(for: firstUser)
            .contains(firstUser.uuidString.lowercased()))
        try cache.accept(appAccountToken: firstToken, for: firstUser)
        #expect(cache.appAccountToken(for: firstUser) == firstToken)
        #expect(cache.appAccountToken(for: secondUser) == nil)
    }

    @Test func changedServerAppAccountTokenFailsClosed() throws {
        let suiteName = "SubscriptionTokenInvariantTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let cache = SubscriptionAccountCache(defaults: defaults)
        let userID = UUID()
        try cache.accept(appAccountToken: UUID(), for: userID)

        var rejected = false
        do {
            try cache.accept(appAccountToken: UUID(), for: userID)
        } catch SubscriptionCacheError.appAccountTokenChanged {
            rejected = true
        } catch {
            rejected = false
        }
        #expect(rejected)
    }

    @Test func onlyTransportFailuresPermitOfflineCache() {
        #expect(SubscriptionFailureClassifier.permitsOfflineCache(
            URLError(.notConnectedToInternet)
        ))
        #expect(!SubscriptionFailureClassifier.permitsOfflineCache(
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad payload"))
        ))
    }

    @Test func exhaustedQuotaBlocksOnlyOnSameKSTDate() {
        #expect(!ServerQuotaAccessPolicy.canAttemptAnalysis(
            remaining: 0,
            usageDate: "2026-08-04",
            timeZone: "Asia/Seoul",
            now: date("2026-08-04T14:59:59Z")
        ))
        #expect(ServerQuotaAccessPolicy.canAttemptAnalysis(
            remaining: 0,
            usageDate: "2026-08-04",
            timeZone: "Asia/Seoul",
            now: date("2026-08-04T15:00:00Z")
        ))
    }

    @Test func missingQuotaSnapshotAllowsServerToDecide() {
        #expect(ServerQuotaAccessPolicy.canAttemptAnalysis(
            remaining: nil,
            usageDate: nil,
            timeZone: nil,
            now: date("2026-08-04T00:00:00Z")
        ))
    }

    private func decode(_ json: String) throws -> ServerEntitlementSnapshot {
        try decoder.decode(ServerEntitlementSnapshot.self, from: Data(json.utf8))
    }

    private func decodingFails(_ json: String) -> Bool {
        do {
            _ = try decode(json)
            return false
        } catch {
            return true
        }
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}

// MARK: - storekit-sync 오류 응답 매핑 (QA-003)
struct StoreKitSyncErrorMapperTests {
    private func body(_ code: String) -> Data {
        Data(#"{"error":{"code":"\#(code)"}}"#.utf8)
    }

    @Test func ownershipConflictsBecomeAccountErrors() {
        #expect(StoreKitSyncErrorMapper.map(status: 409, data: body("subscription_owned_by_another_account"))
            == .subscriptionOwnedByAnotherAccount)
        #expect(StoreKitSyncErrorMapper.map(status: 409, data: body("rebind_not_eligible"))
            == .restoreRebindUnavailable)
    }

    @Test func verificationFailuresAreNotRetriedAsOutages() {
        #expect(StoreKitSyncErrorMapper.map(status: 422, data: body("family_sharing_not_supported"))
            == .familySharingNotSupported)
        #expect(StoreKitSyncErrorMapper.map(status: 422, data: body("transaction_signature_invalid"))
            == .transactionRejected)
    }

    @Test func outagesAndUnknownBodiesStayGeneric() {
        #expect(StoreKitSyncErrorMapper.map(status: 503, data: body("subscription_backend_unavailable")) == nil)
        #expect(StoreKitSyncErrorMapper.map(status: 502, data: Data("<html>".utf8)) == nil)
    }
}

struct SubscriptionPricingTests {
    @Test func savingsUseActualPricesAndRoundDown() {
        #expect(SubscriptionPricing.annualSavingsPercent(monthly: 5, yearly: 36, monthlyCurrency: "USD", yearlyCurrency: "USD") == 40)
        #expect(SubscriptionPricing.annualSavingsPercent(monthly: 5900, yearly: 49000, monthlyCurrency: "KRW", yearlyCurrency: "KRW") == 30)
        #expect(SubscriptionPricing.annualSavingsPercent(monthly: 3, yearly: 24, monthlyCurrency: "JPY", yearlyCurrency: "JPY") == 33)
    }
    @Test func misleadingSavingsAreNotAdvertised() {
        for yearly: Decimal in [0, -1, 60, 61] {
            #expect(SubscriptionPricing.annualSavingsPercent(monthly: 5, yearly: yearly, monthlyCurrency: "USD", yearlyCurrency: "USD") == nil)
        }
        #expect(SubscriptionPricing.annualSavingsPercent(monthly: 0, yearly: 36, monthlyCurrency: "USD", yearlyCurrency: "USD") == nil)
        #expect(SubscriptionPricing.annualSavingsPercent(monthly: 5, yearly: 36, monthlyCurrency: "USD", yearlyCurrency: "KRW") == nil)
    }
}


// A suspended StoreKit/server operation must never follow a later account session.
struct SubscriptionOperationScopeTests {
    @Test func finishingRestrictedRestoreCannotCloseNewerOrNewlyEligibleAccount() throws {
        var scope = SubscriptionOperationScope()
        let first = UUID(), second = UUID()
        scope.activate(first)
        let original = try #require(scope.capture(sessionUserID: first, accessToken: "restore-first"))
        let closedEligible = scope.finishRestrictedManagementOperation(original, sessionUserID: first, isLocallyEligible: true)
        #expect(!closedEligible)
        #expect(scope.accepts(original, sessionUserID: first))
        scope.activate(second)
        let closedNewerAccount = scope.finishRestrictedManagementOperation(original, sessionUserID: second, isLocallyEligible: false)
        #expect(!closedNewerAccount)
        #expect(scope.userID == second)
        let current = try #require(scope.capture(sessionUserID: second, accessToken: "restore-second"))
        let closedRestricted = scope.finishRestrictedManagementOperation(current, sessionUserID: second, isLocallyEligible: false)
        #expect(closedRestricted)
        #expect(scope.userID == nil)
        #expect(!scope.accepts(current, sessionUserID: second))
    }

    @Test func guestRejectsAStaleAuthenticatedSession() {
        var scope = SubscriptionOperationScope()
        let userID = UUID()
        scope.activate(userID)
        scope.deactivate()
        #expect(scope.capture(sessionUserID: userID, accessToken: "synthetic-old-token") == nil)
    }

    @Test func accountSwitchInvalidatesAnInflightOperation() throws {
        var scope = SubscriptionOperationScope()
        let firstUser = UUID()
        let secondUser = UUID()
        scope.activate(firstUser)
        let operation = try #require(scope.capture(sessionUserID: firstUser, accessToken: "synthetic-a"))
        // The provider session can change before its auth event is consumed.
        #expect(!scope.accepts(operation, sessionUserID: secondUser))
        scope.activate(secondUser)
        #expect(!scope.accepts(operation, sessionUserID: secondUser))
        #expect(operation.userID == firstUser)
        #expect(operation.accessToken == "synthetic-a")
    }

    @Test func returningToSameAccountDoesNotReviveAnOldOperation() throws {
        var scope = SubscriptionOperationScope()
        let userID = UUID()
        scope.activate(userID)
        let oldOperation = try #require(scope.capture(sessionUserID: userID, accessToken: "synthetic-before-logout"))
        scope.deactivate()
        scope.activate(userID)
        #expect(!scope.accepts(oldOperation, sessionUserID: userID))
        let newOperation = try #require(scope.capture(sessionUserID: userID, accessToken: "synthetic-after-login"))
        #expect(scope.accepts(newOperation, sessionUserID: userID))
    }

    @Test func sameAccountRefreshKeepsTheRequestTokenPinned() throws {
        var scope = SubscriptionOperationScope()
        let userID = UUID()
        scope.activate(userID)
        let operation = try #require(scope.capture(sessionUserID: userID, accessToken: "synthetic-first-token"))
        scope.activate(userID)
        let refreshed = try #require(scope.capture(sessionUserID: userID, accessToken: "synthetic-refreshed-token"))
        #expect(scope.accepts(operation, sessionUserID: userID))
        #expect(operation.accessToken == "synthetic-first-token")
        #expect(refreshed.accessToken == "synthetic-refreshed-token")
        #expect(!scope.accepts(operation, sessionUserID: nil))
    }
}
