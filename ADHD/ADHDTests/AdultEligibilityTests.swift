import Foundation
import Testing
@testable import ADHD

@MainActor
struct AdultEligibilityTests {
    private final class Server: AdultEligibilityServer {
        var response = AdultEligibilitySnapshot(eligible: true, policyVersion: "adult-v1")
        var error: Error?
        var acceptedTokens: [String] = []
        var queriedTokens: [String] = []
        var acceptBarrier: Barrier?
        func get(accessToken: String) async throws -> AdultEligibilitySnapshot {
            queriedTokens.append(accessToken)
            if let error { throw error }
            return response
        }
        func accept(accessToken: String) async throws -> AdultEligibilitySnapshot {
            acceptedTokens.append(accessToken)
            if let acceptBarrier { await acceptBarrier.pause() }
            if let error { throw error }
            return response
        }
    }

    private final class Barrier {
        private var resume: CheckedContinuation<Void, Never>?
        private var started: CheckedContinuation<Void, Never>?
        private var didStart = false
        func pause() async {
            await withCheckedContinuation { continuation in
                resume = continuation
                didStart = true
                started?.resume()
                started = nil
            }
        }
        func waitUntilStarted() async {
            if didStart { return }
            await withCheckedContinuation { started = $0 }
        }
        func release() { resume?.resume(); resume = nil }
    }

    private func makeDefaults() -> (String, UserDefaults) {
        let name = "adult-eligibility-tests-\(UUID())"
        return (name, UserDefaults(suiteName: name)!)
    }

    @Test func guestAcceptancePersistsButNeverAuthorizesAnAccount() throws {
        let (name, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AdultEligibilityStore(defaults: defaults)
        let account = UUID()
        try store.affirmAdult(for: LocalGuestIdentity.storageID, at: Date(timeIntervalSince1970: 10))
        let reopened = AdultEligibilityStore(defaults: defaults)
        #expect(reopened.status(for: LocalGuestIdentity.storageID) == .accepted)
        #expect(reopened.status(for: account) == .needsConfirmation)
        #expect(reopened.record(for: LocalGuestIdentity.storageID)?.affirmedAt == Date(timeIntervalSince1970: 10))
        #expect(defaults.dictionaryRepresentation().keys.allSatisfy { !$0.contains(account.uuidString) })
    }

    @Test func under18RestrictionSurvivesRestartAccountSwitchAndAccountDeletion() throws {
        let (name, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let account = UUID(), otherAccount = UUID()
        let store = AdultEligibilityStore(defaults: defaults)
        try store.affirmAdult(for: LocalGuestIdentity.storageID)
        try store.recordUnder18(for: account)
        store.removeAccountRecord(for: account)
        let reopened = AdultEligibilityStore(defaults: defaults)
        #expect(reopened.status(for: account) == .restricted)
        #expect(reopened.status(for: otherAccount) == .restricted)
        #expect(reopened.status(for: LocalGuestIdentity.storageID) == .restricted)
        #expect(throws: AdultEligibilityError.self) { try reopened.affirmAdult(for: otherAccount) }
    }

    @Test func oldAcceptanceRequiresCurrentPolicyAndMalformedServerDataDoesNotAuthorize() throws {
        let (name, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let account = UUID()
        let old = AdultEligibilityRecord(decision: .accepted, policyVersion: "adult-old", affirmedAt: .now)
        defaults.set(try JSONEncoder().encode(old), forKey: "mora.adult-eligibility.\(AccountPreferences.scope(for: account)).v1")
        #expect(AdultEligibilityStore(defaults: defaults).status(for: account) == .needsConfirmation)
        #expect(!AdultEligibilitySnapshot(eligible: true, policyVersion: "adult-future").permitsServerUse)
        #expect(!AdultEligibilitySnapshot(eligible: false, policyVersion: "adult-v1").permitsServerUse)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AdultEligibilitySnapshot.self, from: Data("{\"eligible\":true}".utf8))
        }
    }

    @Test func deletionAndBootRoutesOutrankTheGate() {
        let account = UUID()
        #expect(!AdultEligibilityGatePolicy.requiresGate(auth: .deletionPending(userID: account), status: .restricted))
        #expect(!AdultEligibilityGatePolicy.requiresGate(auth: .booting, status: .needsConfirmation))
        #expect(AdultEligibilityGatePolicy.requiresGate(auth: .authenticatedOnline(userID: account), status: .needsConfirmation))
        #expect(AdultEligibilityGatePolicy.requiresGate(auth: .signedOut, status: .restricted))
        #expect(!AdultEligibilityGatePolicy.requiresGate(auth: .authenticatedOfflineLimited(userID: account), status: .accepted))
    }

    @Test func offlineAffirmationAllowsLocalUseButNeverSendsOrAuthorizesServerUse() async throws {
        let (name, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let user = UUID(), server = Server()
        let manager = AdultEligibilityManager(store: .init(defaults: defaults), server: server) {
            Issue.record("Offline affirmation must not load a server session")
            throw AdultEligibilityError.unavailable
        }
        manager.activate(scopeID: user, accountID: user, isOnline: false)
        await manager.affirmAdult(for: user)
        #expect(manager.allowsLocalUse(for: user))
        #expect(server.acceptedTokens.isEmpty)
        await #expect(throws: AdultEligibilityError.self) {
            try await manager.requireServerEligibility(userID: user, accessToken: "offline-token")
        }
        #expect(server.queriedTokens.isEmpty)
    }

    @Test func staleSessionAwaitCannotAcceptForADifferentAccount() async {
        let (name, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let first = UUID(), second = UUID(), server = Server(), sessionBarrier = Barrier()
        let manager = AdultEligibilityManager(store: .init(defaults: defaults), server: server) {
            await sessionBarrier.pause()
            return AdultEligibilitySession(userID: first, accessToken: "first-token")
        }
        manager.activate(scopeID: first, accountID: first, isOnline: true)
        let attempt = Task { await manager.affirmAdult(for: first) }
        await sessionBarrier.waitUntilStarted()
        manager.activate(scopeID: second, accountID: second, isOnline: true)
        sessionBarrier.release()
        await attempt.value
        #expect(server.acceptedTokens.isEmpty)
        #expect(manager.status(for: second) == .needsConfirmation)
        #expect(manager.lastError == nil)
    }

    @Test func lateAcceptanceResponseDoesNotAuthorizeTheNextAccountOrDismissItsGate() async {
        let (name, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let first = UUID(), second = UUID(), server = Server(), barrier = Barrier()
        server.acceptBarrier = barrier
        let manager = AdultEligibilityManager(store: .init(defaults: defaults), server: server) {
            AdultEligibilitySession(userID: first, accessToken: "first-token")
        }
        manager.activate(scopeID: first, accountID: first, isOnline: true)
        let attempt = Task { await manager.affirmAdult(for: first) }
        await barrier.waitUntilStarted()
        manager.activate(scopeID: second, accountID: second, isOnline: true)
        barrier.release()
        await attempt.value
        #expect(server.acceptedTokens == ["first-token"])
        #expect(!manager.allowsLocalUse(for: second))
        #expect(!manager.isSubmitting)
        #expect(manager.lastError == nil)
    }

    @Test func explicitAffirmationIsRequiredAndServerMissingOrFailureFailsClosed() async throws {
        let (name, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let user = UUID(), server = Server()
        let manager = AdultEligibilityManager(store: .init(defaults: defaults), server: server) {
            AdultEligibilitySession(userID: user, accessToken: "account-token")
        }
        manager.activate(scopeID: user, accountID: user, isOnline: true)
        await #expect(throws: AdultEligibilityError.self) {
            try await manager.requireServerEligibility(userID: user, accessToken: "account-token")
        }
        #expect(server.acceptedTokens.isEmpty)
        #expect(server.queriedTokens.isEmpty)
        await manager.affirmAdult(for: user)
        #expect(server.acceptedTokens == ["account-token"])
        try await manager.requireServerEligibility(userID: user, accessToken: "account-token")
        server.response = .init(eligible: false, policyVersion: "adult-v1")
        await #expect(throws: AdultEligibilityError.self) {
            try await manager.requireServerEligibility(userID: user, accessToken: "account-token")
        }
        server.error = URLError(.notConnectedToInternet)
        await #expect(throws: AdultEligibilityError.self) {
            try await manager.requireServerEligibility(userID: user, accessToken: "account-token")
        }
        #expect(server.acceptedTokens.count == 1)
    }

    @Test func newlyAcceptedScopeWaitsForRestrictedScopeCleanup() async {
        let barrier = Barrier()
        var cleanupFinished = false
        var exposureRestored = false
        let coordinator = AccountSessionCleanupCoordinator { _, _ in
            await barrier.pause()
            cleanupFinished = true
        }
        let cleanup = Task { await coordinator.lockLocalExposure(taskManager: TaskManager(), reason: .eligibilityRestricted) }
        await barrier.waitUntilStarted()
        let activation = Task {
            await coordinator.waitForPendingCleanup()
            #expect(cleanupFinished)
            exposureRestored = true
        }
        #expect(!exposureRestored)
        barrier.release()
        await cleanup.value
        await activation.value
        #expect(exposureRestored)
    }
}
