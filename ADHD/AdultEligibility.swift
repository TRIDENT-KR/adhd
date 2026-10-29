import Combine
import Foundation
import Supabase

enum AdultEligibilityDecision: String, Codable { case accepted, rejected }

struct AdultEligibilityRecord: Codable {
    let decision: AdultEligibilityDecision
    let policyVersion: String
    let affirmedAt: Date
}

enum AdultEligibilityStatus: Equatable { case needsConfirmation, accepted, restricted }

/// A self-declaration, not an identity/age verification. No birth date or identity document is stored.
struct AdultEligibilityStore {
    static let policyVersion = "adult-v1"
    private static let deviceRestrictionKey = "mora.adult-eligibility.device-restricted.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func record(for scopeID: UUID) -> AdultEligibilityRecord? {
        guard let data = defaults.data(forKey: key(for: scopeID)) else { return nil }
        return try? JSONDecoder().decode(AdultEligibilityRecord.self, from: data)
    }

    func status(for scopeID: UUID) -> AdultEligibilityStatus {
        if defaults.bool(forKey: Self.deviceRestrictionKey) { return .restricted }
        guard let record = record(for: scopeID) else { return .needsConfirmation }
        // A policy update never converts an earlier under-18 response into a fresh yes/no prompt.
        if record.decision == .rejected { return .restricted }
        return record.policyVersion == Self.policyVersion ? .accepted : .needsConfirmation
    }

    func affirmAdult(for scopeID: UUID, at date: Date = .now) throws {
        guard status(for: scopeID) != .restricted else { throw AdultEligibilityError.restricted }
        try save(.init(decision: .accepted, policyVersion: Self.policyVersion, affirmedAt: date), for: scopeID)
    }

    func recordUnder18(for scopeID: UUID, at date: Date = .now) throws {
        try save(.init(decision: .rejected, policyVersion: Self.policyVersion, affirmedAt: date), for: scopeID)
        defaults.set(true, forKey: Self.deviceRestrictionKey)
    }

    func removeAccountRecord(for userID: UUID) {
        guard userID != LocalGuestIdentity.storageID else { return }
        defaults.removeObject(forKey: key(for: userID))
        // The device restriction is not an account record and must not become a delete/rejoin bypass.
    }

    private func save(_ record: AdultEligibilityRecord, for scopeID: UUID) throws {
        defaults.set(try JSONEncoder().encode(record), forKey: key(for: scopeID))
    }

    private func key(for scopeID: UUID) -> String {
        "mora.adult-eligibility.\(AccountPreferences.scope(for: scopeID)).v1"
    }
}

struct AdultEligibilitySnapshot: Decodable, Equatable {
    let eligible: Bool
    let policyVersion: String
    var permitsServerUse: Bool { eligible && policyVersion == AdultEligibilityStore.policyVersion }
}

struct AdultEligibilitySession {
    let userID: UUID
    let accessToken: String
}

enum AdultEligibilityError: Error, Equatable {
    case required, restricted, unavailable, accountChanged
}

@MainActor
protocol AdultEligibilityServer {
    func get(accessToken: String) async throws -> AdultEligibilitySnapshot
    func accept(accessToken: String) async throws -> AdultEligibilitySnapshot
}

struct SupabaseAdultEligibilityServer: AdultEligibilityServer {
    func get(accessToken: String) async throws -> AdultEligibilitySnapshot {
        let response: PostgrestResponse<AdultEligibilitySnapshot> = try await SupabaseConfig
            .requestClient(accessToken: accessToken).rpc("get_adult_eligibility").execute()
        return response.value
    }

    func accept(accessToken: String) async throws -> AdultEligibilitySnapshot {
        let response: PostgrestResponse<AdultEligibilitySnapshot> = try await SupabaseConfig
            .requestClient(accessToken: accessToken)
            .rpc("accept_adult_eligibility", params: ["p_policy_version": AdultEligibilityStore.policyVersion])
            .execute()
        return response.value
    }
}

@MainActor
final class AdultEligibilityManager: ObservableObject {
    static let shared = AdultEligibilityManager()
    @Published private(set) var revision = 0
    @Published private(set) var isSubmitting = false
    @Published private(set) var lastError: AdultEligibilityError?
    private(set) var activeScopeID: UUID?
    private var activeAccountID: UUID?
    private var isOnline = false
    private var generation = UUID()
    private let store: AdultEligibilityStore
    private let server: any AdultEligibilityServer
    private let sessionProvider: () async throws -> AdultEligibilitySession

    convenience init() {
        self.init(store: AdultEligibilityStore(), server: SupabaseAdultEligibilityServer()) {
            let session = try await supabase.auth.session
            return AdultEligibilitySession(userID: session.user.id, accessToken: session.accessToken)
        }
    }

    init(store: AdultEligibilityStore, server: any AdultEligibilityServer,
         sessionProvider: @escaping () async throws -> AdultEligibilitySession) {
        self.store = store
        self.server = server
        self.sessionProvider = sessionProvider
    }

    func status(for scopeID: UUID) -> AdultEligibilityStatus { store.status(for: scopeID) }
    func allowsLocalUse(for scopeID: UUID) -> Bool { status(for: scopeID) == .accepted }

    func activate(scopeID: UUID?, accountID: UUID?, isOnline: Bool) {
        guard activeScopeID != scopeID || activeAccountID != accountID || self.isOnline != isOnline else { return }
        generation = UUID()
        activeScopeID = scopeID
        activeAccountID = accountID
        self.isOnline = isOnline
        isSubmitting = false
        lastError = nil
    }

    /// Called only by the visible, explicit 18+ affirmation action for this scope.
    func affirmAdult(for scopeID: UUID) async {
        guard activeScopeID == scopeID, !isSubmitting else { return }
        let expectedGeneration = generation
        do {
            try store.affirmAdult(for: scopeID)
            revision += 1
            lastError = nil
            guard let userID = activeAccountID else { return }
            guard isOnline else { throw AdultEligibilityError.unavailable }
            isSubmitting = true
            defer { if generation == expectedGeneration { isSubmitting = false } }
            let session = try await sessionProvider()
            try requireCurrent(scopeID: scopeID, accountID: userID, generation: expectedGeneration)
            guard session.userID == userID, !session.accessToken.isEmpty else { throw AdultEligibilityError.accountChanged }
            let response = try await server.accept(accessToken: session.accessToken)
            try requireCurrent(scopeID: scopeID, accountID: userID, generation: expectedGeneration)
            guard response.permitsServerUse else { throw AdultEligibilityError.required }
        } catch {
            guard generation == expectedGeneration else { return }
            lastError = error as? AdultEligibilityError ?? .unavailable
        }
    }

    func recordUnder18(for scopeID: UUID) {
        guard activeScopeID == scopeID else { return }
        do {
            try store.recordUnder18(for: scopeID)
            generation = UUID()
            isSubmitting = false
            lastError = nil
            revision += 1
        } catch { lastError = .unavailable }
    }

    /// Recheck the server before each AI request or new purchase. Local acceptance cannot authorize billing.
    /// Apple 계정은 자기 계정 범위의 확인만, 익명 계정은 그 계정을 만든 기기 범위의 확인만 씁니다.
    func requireServerEligibility(userID: UUID, accessToken: String) async throws {
        let expectedGeneration = generation
        guard let scopeID = activeScopeID,
              AdultEligibilityScopePolicy.isLocalScope(scopeID, validFor: userID) else {
            throw AdultEligibilityError.accountChanged
        }
        try requireCurrent(scopeID: scopeID, accountID: userID, generation: expectedGeneration)
        guard isOnline, !accessToken.isEmpty else { throw AdultEligibilityError.unavailable }
        var response: AdultEligibilitySnapshot
        do { response = try await server.get(accessToken: accessToken) }
        catch { throw AdultEligibilityError.unavailable }
        try Task.checkCancellation()
        try requireCurrent(scopeID: scopeID, accountID: userID, generation: expectedGeneration)
        if !response.permitsServerUse, scopeID == LocalGuestIdentity.storageID {
            // 익명 계정은 기기에서 이미 한 18+ 확인 뒤에만 만들어집니다. 그 확인을 이 계정의 서버 기록으로 한 번 옮깁니다.
            do { response = try await server.accept(accessToken: accessToken) }
            catch { throw AdultEligibilityError.unavailable }
            try Task.checkCancellation()
            try requireCurrent(scopeID: scopeID, accountID: userID, generation: expectedGeneration)
        }
        guard response.permitsServerUse else { throw AdultEligibilityError.required }
    }

    func removeAccountRecord(for userID: UUID) {
        store.removeAccountRecord(for: userID)
        revision += 1
    }

    private func requireCurrent(scopeID: UUID, accountID: UUID, generation expected: UUID) throws {
        guard generation == expected, activeScopeID == scopeID, activeAccountID == accountID else {
            throw AdultEligibilityError.accountChanged
        }
        guard allowsLocalUse(for: scopeID) else { throw AdultEligibilityError.required }
    }
}

/// 어떤 로컬 확인이 서버 계정의 확인을 대신할 수 있는지 정합니다.
/// Apple 계정은 자기 범위만, 익명 계정은 기기 범위만 씁니다. 기기 확인이 Apple 계정을 대신하지는 않습니다
/// (기기 범위와 Apple 계정이 함께 활성화되는 상태는 없고, 익명 계정에서만 짝지어집니다).
enum AdultEligibilityScopePolicy {
    static func isLocalScope(_ scopeID: UUID, validFor accountID: UUID) -> Bool {
        scopeID == accountID || scopeID == LocalGuestIdentity.storageID
    }
}

/// Deletion must always outrank the age gate; a guest response never substitutes for an account response.
enum AdultEligibilityGatePolicy {
    static func requiresGate(auth: AuthAccessState, status: AdultEligibilityStatus) -> Bool {
        guard auth.localStorageUserID != nil else { return false }
        return status != .accepted
    }
}
