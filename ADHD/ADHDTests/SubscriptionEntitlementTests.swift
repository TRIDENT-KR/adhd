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
