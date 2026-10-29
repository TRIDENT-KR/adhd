import Foundation
import Combine
import Supabase
import AuthenticationServices
import CryptoKit
import Security

enum AuthAccessState: Hashable {
    case booting
    case authenticatedOnline(userID: UUID)
    case authenticatedOfflineLimited(userID: UUID)
    case signedOut
    case deletionPending(userID: UUID)
    case lockedInvalidSession

    /// 로컬 전용 식별자입니다. accountUserID와 서버 인증에는 게스트 ID를 사용하지 않습니다.
    var localStorageUserID: UUID? {
        switch self {
        case .signedOut, .lockedInvalidSession: return LocalGuestIdentity.storageID
        case .authenticatedOnline(let id), .authenticatedOfflineLimited(let id): return id
        case .booting, .deletionPending: return nil
        }
    }

    var isGuest: Bool {
        self == .signedOut || self == .lockedInvalidSession
    }

    var exposedUserID: UUID? {
        switch self {
        case .authenticatedOnline(let userID), .authenticatedOfflineLimited(let userID):
            return userID
        case .booting, .signedOut, .deletionPending, .lockedInvalidSession:
            return nil
        }
    }

    var accountUserID: UUID? {
        switch self {
        case .authenticatedOnline(let userID),
             .authenticatedOfflineLimited(let userID),
             .deletionPending(let userID):
            return userID
        case .booting, .signedOut, .lockedInvalidSession:
            return nil
        }
    }
}

enum AccountDeletionProgressStatus: String, Codable {
    case requesting
    case running
    case retryWait = "retry_wait"
    case completed
}

/// 이전 세션 검사/SDK 이벤트가 명시적 로그아웃이나 새 로그인 시도를 역전시키지 못하게 합니다.
struct AuthSessionTransitionGuard {
    private(set) var generation: UInt64 = 0
    private(set) var allowsBackgroundSession: Bool
    private(set) var interactiveGeneration: UInt64?

    init(isLocallyLocked: Bool) { allowsBackgroundSession = !isLocallyLocked }

    mutating func invalidate() {
        generation &+= 1
        allowsBackgroundSession = false
        interactiveGeneration = nil
    }

    mutating func beginInteractiveSignIn() -> UInt64 {
        invalidate()
        interactiveGeneration = generation
        return generation
    }

    @discardableResult
    mutating func finishInteractiveSignIn(_ attempt: UInt64, succeeded: Bool) -> Bool {
        guard interactiveGeneration == attempt, generation == attempt else { return false }
        interactiveGeneration = nil
        allowsBackgroundSession = succeeded
        return true
    }

    func permitsBackgroundResult(_ startedGeneration: UInt64) -> Bool {
        generation == startedGeneration && allowsBackgroundSession && interactiveGeneration == nil
    }

    mutating func didAcceptSession() {
        generation &+= 1
    }

    static func expiryCheckDelay(expiresAt: TimeInterval, now: TimeInterval) -> TimeInterval {
        max(0.1, expiresAt - now + 0.1)
    }

    /// 만료된 세션을 네트워크 문제로 갱신하지 못했을 때 다시 시도하기까지의 대기 시간입니다.
    static func offlineRefreshRetryDelay(afterFailures failures: Int) -> TimeInterval {
        min(300, 15 * pow(2, Double(min(max(failures, 0), 5))))
    }
}

/// 세션 갱신 실패 중 '세션이 무효'가 아니라 '지금 확인할 수 없음'에 해당하는 오류를 가립니다.
/// 이 경우 refresh token을 지우지 않고 오프라인 제한 상태로 두었다가 다시 시도합니다.
enum AuthRefreshFailurePolicy {
    static func isTransient(_ error: Error) -> Bool {
        if error is URLError { return true }
        if (error as NSError).domain == NSURLErrorDomain { return true }
        if let authError = error as? AuthError, case .api(_, _, _, let response) = authError {
            return response.statusCode == 429 || (500...599).contains(response.statusCode)
        }
        return false
    }
}

private enum AuthValidationError: Error {
    case identityMismatch
    case deletionNotCompleted
}

enum AccountDeletionClientError: LocalizedError {
    case onlineSessionRequired
    case appleCredentialMissing
    case appleAccountMismatch
    case appleReauthenticationRequired
    case invalidServerResponse
    case statusUnavailable

    var errorDescription: String? {
        switch self {
        case .onlineSessionRequired:
            return L.authRelease.onlineRequired
        case .appleCredentialMissing:
            return L.authRelease.appleCredentialMissing
        case .appleAccountMismatch:
            return L.authRelease.appleAccountMismatch
        case .appleReauthenticationRequired:
            return L.authRelease.appleReauthenticationRequired
        case .invalidServerResponse, .statusUnavailable:
            return L.authRelease.deletionUnavailable
        }
    }
}

private struct AccountDeletionEnvelope: Codable {
    let requestId: UUID
    let jobId: UUID
    let status: AccountDeletionProgressStatus
    let statusToken: String?
}

struct AccountDeletionServerError: Decodable {
    struct Detail: Decodable { let code: String }
    let error: Detail
    let requestId: UUID?
    let jobId: UUID?
    let status: AccountDeletionProgressStatus?
    let statusToken: String?
}

struct PendingAccountDeletion: Codable {
    let userID: UUID
    let requestID: UUID
    var jobID: UUID?
    var status: AccountDeletionProgressStatus
    var statusToken: String?
    var needsAppleReauthentication: Bool

    var shouldPoll: Bool {
        statusToken != nil && !needsAppleReauthentication && status != .completed
    }

    func applying(_ response: AccountDeletionServerError) throws -> Self {
        if let responseRequestID = response.requestId, responseRequestID != requestID {
            throw AccountDeletionClientError.invalidServerResponse
        }
        var updated = self
        updated.jobID = response.jobId ?? jobID
        updated.status = response.status ?? .retryWait
        if let token = response.statusToken {
            guard token.count == 43 else { throw AccountDeletionClientError.invalidServerResponse }
            updated.statusToken = token
        }
        updated.needsAppleReauthentication = response.error.code == "apple_reauth_required"
        return updated
    }
}

protocol AccountDeletionPersistence {
    func load() -> PendingAccountDeletion?
    func save(_ pending: PendingAccountDeletion) throws
    func clear() throws
}

private struct AccountDeletionPollingStore: AccountDeletionPersistence {
    private let service = "com.trident-KR.ADHD.account-deletion.v1"
    private let account = "pending"

    func load() -> PendingAccountDeletion? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(PendingAccountDeletion.self, from: data)
    }

    func save(_ pending: PendingAccountDeletion) throws {
        let data = try JSONEncoder().encode(pending)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
                throw AccountDeletionClientError.statusUnavailable
            }
        } else if updateStatus != errSecSuccess {
            throw AccountDeletionClientError.statusUnavailable
        }
    }

    func clear() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AccountDeletionClientError.statusUnavailable
        }
    }
}

class AuthManager: NSObject, ObservableObject {
    @Published private(set) var session: Session?
    @Published var isProcessing = false
    /// 세션 로딩이 완료되었는지 여부 (초기 스플래시 방지)
    @Published private(set) var isSessionLoaded = false
    @Published private(set) var accessState: AuthAccessState = .booting
    @Published private(set) var accountDeletionStatus: AccountDeletionProgressStatus?
    @Published private(set) var accountDeletionRequestID: UUID?
    @Published private(set) var accountDeletionNeedsAppleReauthentication = false
    @Published private(set) var accountDeletionErrorCode: String?
    @Published private(set) var signInFailed = false
    @Published private(set) var showsDeletionCompletion = false

    /// 서버 완료 표식을 로컬 파일·설정 삭제가 끝날 때까지 Keychain에 보존합니다.
    var pendingLocalDeletionUserID: UUID? {
        guard let pending = deletionPollingStore.load(), pending.status == .completed else { return nil }
        return pending.userID
    }

    /// Settings에서 사용할 이메일 (Auth 모듈 import 없이 접근)
    var userEmail: String? {
        session?.user.email
    }

    /// AI·entitlement 확인·계정 변경처럼 서버가 필요한 기능의 공통 게이트입니다.
    var canUseServerFeatures: Bool {
        if case .authenticatedOnline = accessState { return true }
        return false
    }

    private var currentNonce: String?
    private var accountDeletionNonce: String?
    private var startupCachedSession: Session?
    private var lastKnownUserID: UUID?
    private var authStateObservationTask: Task<Void, Never>?
    private var sessionExpiryTask: Task<Void, Never>?
    private var offlineRefreshFailures = 0
    private var deletionPollingTask: Task<Void, Never>?
    private let deletionPollingStore: any AccountDeletionPersistence
    private let deletionNoticeDefaults: UserDefaults
    private static let localSessionLockKey = "mora.local-session-lock.v1"
    private var sessionTransition: AuthSessionTransitionGuard
    private var isSigningOut = false

    override convenience init() {
        self.init(
            deletionPollingStore: AccountDeletionPollingStore(),
            deletionNoticeDefaults: .standard,
            observesAuthentication: true
        )
    }

    /// Test seams avoid live authentication and let deletion persistence failures be exercised.
    init(
        deletionPollingStore: any AccountDeletionPersistence,
        deletionNoticeDefaults: UserDefaults,
        observesAuthentication: Bool
    ) {
        self.deletionPollingStore = deletionPollingStore
        self.deletionNoticeDefaults = deletionNoticeDefaults
        let isLocallyLocked = deletionNoticeDefaults.integer(forKey: Self.localSessionLockKey) != 0
        self.sessionTransition = AuthSessionTransitionGuard(isLocallyLocked: isLocallyLocked)
        let cachedSession = observesAuthentication && !isLocallyLocked ? supabase.auth.currentSession : nil
        startupCachedSession = cachedSession
        lastKnownUserID = cachedSession?.user.id
        super.init()
        showsDeletionCompletion = deletionNoticeDefaults.bool(forKey: "mora.account-deletion-completion-notice.v1")
        guard observesAuthentication else { return }

        authStateObservationTask = Task { [weak self] in
            for await change in supabase.auth.authStateChanges {
                guard let self else { return }
                await self.consumeAuthChange(event: change.event, session: change.session)
            }
        }

        Task { [weak self] in
            await self?.checkSession()
        }
    }

    deinit {
        authStateObservationTask?.cancel()
        sessionExpiryTask?.cancel()
        deletionPollingTask?.cancel()
    }

    @MainActor
    func checkSession() async {
        if let pending = deletionPollingStore.load() {
            exposePendingDeletion(pending)
            startDeletionPollingIfPossible()
            return
        }
        guard sessionTransition.allowsBackgroundSession else {
            exposeLocallyLockedSession()
            return
        }
        let startedGeneration = sessionTransition.generation
        let fallbackSession = session ?? supabase.auth.currentSession ?? startupCachedSession

        do {
            let (refreshedSession, currentUser) = try await Self.validateProviderSession()
            guard sessionTransition.permitsBackgroundResult(startedGeneration) else { return }
            guard !refreshedSession.isExpired else {
                await lockInvalidSessionAndClearProviderCache()
                return
            }

            guard sessionTransition.permitsBackgroundResult(startedGeneration),
                  matchesCurrentProviderSession(refreshedSession) else { return }
            guard currentUser.id == refreshedSession.user.id else {
                throw AuthValidationError.identityMismatch
            }
            acceptAuthenticatedSession(refreshedSession, isOnline: true)
        } catch {
            guard sessionTransition.permitsBackgroundResult(startedGeneration) else { return }
            if isDefinitiveInvalidSession(error) {
                await lockInvalidSessionAndClearProviderCache()
            } else if let fallbackSession, matchesCurrentProviderSession(fallbackSession),
                      !fallbackSession.isExpired || AuthRefreshFailurePolicy.isTransient(error) {
                // 만료된 세션이라도 갱신 실패가 네트워크·서버 일시 장애 때문이면 무효로 보지 않습니다.
                acceptAuthenticatedSession(fallbackSession, isOnline: false)
            } else if fallbackSession == nil {
                session = nil
                accessState = .signedOut
                isSessionLoaded = true
            } else {
                await lockInvalidSessionAndClearProviderCache()
            }
        }
    }

    /// 실행 때 서버 검증이 오래 걸려도 빈 로딩 화면에 묶이지 않도록 제한 시간을 둡니다.
    /// 시간을 넘기면 URLError(.timedOut)로 끝나 일시 장애처럼 오프라인 제한 상태로 열고, 연결되면 다시 검증합니다.
    private static func validateProviderSession(timeout: TimeInterval = 8) async throws -> (Session, User) {
        let client = supabase
        let timeoutNanoseconds = UInt64(timeout * 1_000_000_000)
        return try await withThrowingTaskGroup(of: (Session, User).self) { group in
            group.addTask {
                let session = try await client.auth.session
                let user = try await client.auth.user(jwt: session.accessToken)
                return (session, user)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw URLError(.timedOut) }
            return result
        }
    }

    /// 네트워크 변화는 세션 유효성과 별도 상태로 관리합니다.
    @MainActor
    func handleConnectivityChange(isConnected: Bool) async {
        if let pending = deletionPollingStore.load() {
            exposePendingDeletion(pending)
            if isConnected { startDeletionPollingIfPossible() }
            return
        }
        guard sessionTransition.allowsBackgroundSession else {
            exposeLocallyLockedSession()
            return
        }
        if !isConnected {
            let fallbackSession = session ?? supabase.auth.currentSession ?? startupCachedSession
            // 연결이 끊긴 것 자체는 세션 무효의 근거가 아닙니다. 만료됐더라도 다시 연결되면 갱신합니다.
            if let fallbackSession, matchesCurrentProviderSession(fallbackSession) {
                acceptAuthenticatedSession(fallbackSession, isOnline: false)
            } else if fallbackSession == nil {
                session = nil
                accessState = .signedOut
                isSessionLoaded = true
            } else {
                await lockInvalidSessionAndClearProviderCache()
            }
            return
        }

        guard isSessionLoaded else { return }
        if case .authenticatedOfflineLimited = accessState {
            await checkSession()
        }
    }

    /// 서버 sign-out 성공 여부와 무관하게 호출 즉시 로컬 화면과 세션을 잠급니다.
    @MainActor
    func signOut() async {
        sessionTransition.invalidate()
        deletionNoticeDefaults.set(1, forKey: Self.localSessionLockKey)
        isSigningOut = true
        isProcessing = true
        defer { isSigningOut = false; isProcessing = false }
        lastKnownUserID = session?.user.id ?? accessState.accountUserID ?? lastKnownUserID
        session = nil
        startupCachedSession = nil
        sessionExpiryTask?.cancel()
        accessState = .signedOut
        isSessionLoaded = true

        // 이 기기의 세션만 끝냅니다. 기본값(.global)은 같은 계정의 다른 기기까지 로그아웃시킵니다.
        // .local은 서버 요청 전에 로컬 세션부터 지우므로, 서버 폐기가 실패해도 캐시된 세션이 남지 않습니다.
        do {
            try await supabase.auth.signOut(scope: .local)
        } catch {
            print("auth_sign_out_failed")
        }
    }

    func prepareAppleAccountDeletionRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = randomNonceString()
        accountDeletionNonce = nonce
        request.requestedScopes = []
        request.nonce = sha256(nonce)
    }

    /// 삭제 직전 Apple 재인증으로 동일한 Mora 계정의 최근 Supabase 세션과 1회용 code를 얻습니다.
    @MainActor
    func reauthenticateForAccountDeletion(
        _ result: Result<ASAuthorization, Error>
    ) async throws -> String {
        let expectedUserID: UUID
        switch accessState {
        case .authenticatedOnline(let userID), .deletionPending(let userID):
            expectedUserID = userID
        case .booting, .authenticatedOfflineLimited, .signedOut, .lockedInvalidSession:
            throw AccountDeletionClientError.onlineSessionRequired
        }
        guard case .success(let authorization) = result,
              let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let identityTokenData = credential.identityToken,
              let identityToken = String(data: identityTokenData, encoding: .utf8),
              let authorizationCodeData = credential.authorizationCode,
              let authorizationCode = String(data: authorizationCodeData, encoding: .utf8),
              !authorizationCode.isEmpty,
              let nonce = accountDeletionNonce else {
            accountDeletionNonce = nil
            throw AccountDeletionClientError.appleCredentialMissing
        }

        defer { accountDeletionNonce = nil }
        let refreshedSession = try await supabase.auth.signInWithIdToken(
            credentials: .init(provider: .apple, idToken: identityToken, nonce: nonce)
        )
        guard refreshedSession.user.id == expectedUserID else {
            try? await supabase.auth.signOut(scope: .local)
            await lockInvalidSessionAndClearProviderCache()
            throw AccountDeletionClientError.appleAccountMismatch
        }
        if deletionPollingStore.load() == nil {
            acceptAuthenticatedSession(refreshedSession, isOnline: true)
        } else {
            self.session = refreshedSession
            startupCachedSession = refreshedSession
            lastKnownUserID = expectedUserID
        }
        return authorizationCode
    }

    /// 최종 확인 뒤 요청 ID를 먼저 안전 저장하고, 서버 완료가 확인될 때까지 로컬 데이터를 잠급니다.
    @MainActor
    func deleteAccount(appleAuthorizationCode: String) async throws {
        let userID: UUID
        switch accessState {
        case .authenticatedOnline(let authenticatedUserID),
             .deletionPending(let authenticatedUserID):
            userID = authenticatedUserID
        case .booting, .authenticatedOfflineLimited, .signedOut, .lockedInvalidSession:
            throw AccountDeletionClientError.onlineSessionRequired
        }
        guard let session,
              session.user.id == userID,
              !appleAuthorizationCode.isEmpty else {
            throw AccountDeletionClientError.onlineSessionRequired
        }

        var pending = deletionPollingStore.load()
        if pending?.userID != userID {
            pending = PendingAccountDeletion(
                userID: userID,
                requestID: UUID(),
                jobID: nil,
                status: .requesting,
                statusToken: nil,
                needsAppleReauthentication: false
            )
        }
        guard let pending else { throw AccountDeletionClientError.statusUnavailable }
        try deletionPollingStore.save(pending)
        exposePendingDeletion(pending)

        let headers = ["Authorization": "Bearer \(session.accessToken)"]
        let body = [
            "requestId": pending.requestID.uuidString.lowercased(),
            "appleAuthorizationCode": appleAuthorizationCode,
        ]
        let options = FunctionInvokeOptions(headers: headers, body: body)

        do {
            let response: AccountDeletionEnvelope = try await supabase.functions.invoke(
                "delete-account",
                options: options
            )
            try applyDeletionEnvelope(response, to: pending)
            startDeletionPollingIfPossible()
        } catch {
            if let serverError = decodeAccountDeletionServerError(error) {
                try applyDeletionServerError(serverError, to: pending)
                if !accountDeletionNeedsAppleReauthentication {
                    startDeletionPollingIfPossible()
                }
                if serverError.error.code == "apple_reauth_required" {
                    throw AccountDeletionClientError.appleReauthenticationRequired
                }
            } else {
                accountDeletionErrorCode = "deletion_request_unavailable"
            }
            print("account_deletion_request_failed")
            throw error
        }
    }

    /// 앱 재실행 후에도 Keychain의 request ID/status token으로만 저빈도 상태 조회를 재개합니다.
    @MainActor
    func refreshAccountDeletionStatus() async throws {
        guard var pending = deletionPollingStore.load() else {
            throw AccountDeletionClientError.statusUnavailable
        }
        guard pending.status != .completed else { return }
        guard let statusToken = pending.statusToken else {
            pending.needsAppleReauthentication = true
            try deletionPollingStore.save(pending)
            accountDeletionNeedsAppleReauthentication = true
            deletionPollingTask?.cancel()
            deletionPollingTask = nil
            throw AccountDeletionClientError.appleReauthenticationRequired
        }
        let body = [
            "action": "status",
            "requestId": pending.requestID.uuidString.lowercased(),
            "statusToken": statusToken,
        ]
        do {
            let response: AccountDeletionEnvelope = try await supabase.functions.invoke(
                "delete-account",
                options: FunctionInvokeOptions(body: body)
            )
            try applyDeletionEnvelope(response, to: pending)
        } catch {
            if let serverError = decodeAccountDeletionServerError(error) {
                try handleDeletionStatusServerError(serverError)
                if accountDeletionNeedsAppleReauthentication {
                    throw AccountDeletionClientError.appleReauthenticationRequired
                }
            } else {
                accountDeletionErrorCode = "deletion_status_unavailable"
            }
            throw error
        }
    }

    /// 동기 응답, polling 또는 auth userDeleted event가 실제 완료를 알릴 때의 단일 진입점입니다.
    @MainActor
    func confirmAccountDeletionCompleted(for userID: UUID) {
        var pending = deletionPollingStore.load() ?? PendingAccountDeletion(
            userID: userID, requestID: UUID(), jobID: nil, status: .completed,
            statusToken: nil, needsAppleReauthentication: false
        )
        guard pending.userID == userID else { return }
        pending.status = .completed
        pending.needsAppleReauthentication = false
        do {
            // Write before publishing completion. A crash now must still resume local cleanup.
            try deletionPollingStore.save(pending)
        } catch {
            accountDeletionErrorCode = "local_deletion_marker_unavailable"
            return
        }
        deletionPollingTask?.cancel()
        deletionPollingTask = nil
        sessionTransition.invalidate()
        deletionNoticeDefaults.set(1, forKey: Self.localSessionLockKey)
        exposePendingDeletion(pending)
        accountDeletionErrorCode = nil
        session = nil
        startupCachedSession = nil
        NotificationCenter.default.post(name: .moraAccountDeletionCompleted, object: userID)
    }

    @MainActor
    func finishLocalAccountDeletion(for userID: UUID) throws {
        guard pendingLocalDeletionUserID == userID else { return }
        // A completion notice also survives termination between cleanup and the next launch.
        deletionNoticeDefaults.set(true, forKey: "mora.account-deletion-completion-notice.v1")
        try deletionPollingStore.clear()
        showsDeletionCompletion = true
        accountDeletionStatus = .completed
        accountDeletionRequestID = nil
        accountDeletionNeedsAppleReauthentication = false
        accountDeletionErrorCode = nil
        lastKnownUserID = nil
        session = nil
        startupCachedSession = nil
        accessState = .signedOut
        isSessionLoaded = true
    }

    @MainActor
    func dismissDeletionCompletion() {
        deletionNoticeDefaults.removeObject(forKey: "mora.account-deletion-completion-notice.v1")
        showsDeletionCompletion = false
    }

    @MainActor
    private func exposePendingDeletion(_ pending: PendingAccountDeletion) {
        lastKnownUserID = pending.userID
        sessionExpiryTask?.cancel()
        accessState = .deletionPending(userID: pending.userID)
        isSessionLoaded = true
        accountDeletionStatus = pending.status
        accountDeletionRequestID = pending.requestID
        accountDeletionNeedsAppleReauthentication = pending.needsAppleReauthentication
    }

    @MainActor
    private func applyDeletionEnvelope(
        _ envelope: AccountDeletionEnvelope,
        to existing: PendingAccountDeletion
    ) throws {
        guard envelope.requestId == existing.requestID else {
            throw AccountDeletionClientError.invalidServerResponse
        }
        if envelope.status == .completed {
            confirmAccountDeletionCompleted(for: existing.userID)
            Task { try? await supabase.auth.signOut(scope: .local) }
            print("account_deletion_completed")
            return
        }

        let token = envelope.statusToken ?? existing.statusToken
        guard let token, token.count == 43 else {
            throw AccountDeletionClientError.invalidServerResponse
        }
        var pending = existing
        pending.jobID = envelope.jobId
        pending.status = envelope.status
        pending.statusToken = token
        pending.needsAppleReauthentication = false
        try deletionPollingStore.save(pending)
        accountDeletionErrorCode = nil
        exposePendingDeletion(pending)
    }

    @MainActor
    private func applyDeletionServerError(
        _ response: AccountDeletionServerError,
        to existing: PendingAccountDeletion
    ) throws {
        let pending = try existing.applying(response)
        try deletionPollingStore.save(pending)
        accountDeletionErrorCode = response.error.code
        exposePendingDeletion(pending)
    }

    @MainActor
    func handleDeletionStatusServerError(_ response: AccountDeletionServerError) throws {
        guard let pending = deletionPollingStore.load() else {
            throw AccountDeletionClientError.statusUnavailable
        }
        try applyDeletionServerError(response, to: pending)
        if accountDeletionNeedsAppleReauthentication {
            deletionPollingTask?.cancel()
            deletionPollingTask = nil
        }
    }

    private func decodeAccountDeletionServerError(
        _ error: Error
    ) -> AccountDeletionServerError? {
        guard let functionsError = error as? FunctionsError,
              case .httpError(_, let data) = functionsError else { return nil }
        return try? JSONDecoder().decode(AccountDeletionServerError.self, from: data)
    }

    @MainActor
    private func startDeletionPollingIfPossible() {
        guard let pending = deletionPollingStore.load(), pending.shouldPoll else { return }

        deletionPollingTask?.cancel()
        deletionPollingTask = Task { [weak self] in
            let delays: [UInt64] = [2, 4, 8, 15, 15, 15]
            for delay in delays {
                do {
                    try await Task.sleep(nanoseconds: delay * 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    try await self?.refreshAccountDeletionStatus()
                    if self?.accountDeletionStatus == .completed { return }
                    if self?.accountDeletionNeedsAppleReauthentication == true { return }
                } catch is CancellationError {
                    return
                } catch {
                    if self?.accountDeletionNeedsAppleReauthentication == true { return }
                    continue
                }
            }
        }
    }

    @MainActor
    private func acceptAuthenticatedSession(_ session: Session, isOnline: Bool) {
        guard sessionTransition.allowsBackgroundSession else { return }
        sessionTransition.didAcceptSession()
        if let pending = deletionPollingStore.load() {
            self.session = session.user.id == pending.userID ? session : nil
            startupCachedSession = self.session
            exposePendingDeletion(pending)
            return
        }
        self.session = session
        startupCachedSession = session
        lastKnownUserID = session.user.id
        accessState = isOnline
            ? .authenticatedOnline(userID: session.user.id)
            : .authenticatedOfflineLimited(userID: session.user.id)
        isSessionLoaded = true
        if session.isExpired {
            scheduleOfflineRefreshRetry(for: session.user.id)
        } else {
            offlineRefreshFailures = 0
            scheduleExpiryCheck(for: session)
        }
    }

    @MainActor
    private func lockInvalidSessionAndClearProviderCache() async {
        sessionTransition.invalidate()
        lastKnownUserID = session?.user.id ?? startupCachedSession?.user.id ?? lastKnownUserID
        // 로그인한 적 없는 게스트(세션 없음)는 '만료' 상태(2)로 남기지 않습니다.
        // 2로 저장하면 다음 실행부터 계정을 만든 적도 없는 사용자에게 만료 배너가 뜹니다.
        deletionNoticeDefaults.set(lastKnownUserID == nil ? 1 : 2, forKey: Self.localSessionLockKey)
        session = nil
        startupCachedSession = nil
        sessionExpiryTask?.cancel()
        accessState = lastKnownUserID == nil ? .signedOut : .lockedInvalidSession
        isSessionLoaded = true
        try? await supabase.auth.signOut(scope: .local)
    }

    @MainActor
    private func consumeAuthChange(event: AuthChangeEvent, session: Session?) async {
        switch event {
        case .initialSession:
            // 캐시 이벤트만으로 저장소를 열지 않습니다. checkSession이 유효성을 분류합니다.
            break

        case .signedIn, .tokenRefreshed:
            guard sessionTransition.permitsBackgroundResult(sessionTransition.generation) else { return }
            guard let session, matchesCurrentProviderSession(session) else { return }
            if !session.isExpired {
                acceptAuthenticatedSession(session, isOnline: true)
            } else {
                await lockInvalidSessionAndClearProviderCache()
            }

        case .signedOut:
            // A queued sign-out from an older provider session cannot close a newer login.
            guard supabase.auth.currentSession == nil else { return }
            guard sessionTransition.interactiveGeneration == nil else { return }
            self.session = nil
            startupCachedSession = nil
            sessionExpiryTask?.cancel()
            if let pending = deletionPollingStore.load() {
                exposePendingDeletion(pending)
            } else if accessState != .signedOut {
                if sessionTransition.allowsBackgroundSession {
                    sessionTransition.invalidate()
                    deletionNoticeDefaults.set(lastKnownUserID == nil ? 1 : 2, forKey: Self.localSessionLockKey)
                }
                exposeLocallyLockedSession()
            }

        case .userDeleted:
            if let userID = session?.user.id ?? lastKnownUserID,
               userID == accessState.accountUserID || userID == deletionPollingStore.load()?.userID {
                confirmAccountDeletionCompleted(for: userID)
            }

        case .userUpdated:
            guard sessionTransition.permitsBackgroundResult(sessionTransition.generation) else { return }
            if let session,
               session.user.id == accessState.accountUserID,
               !session.isExpired,
               matchesCurrentProviderSession(session) {
                acceptAuthenticatedSession(session, isOnline: true)
            }

        case .passwordRecovery, .mfaChallengeVerified:
            break
        }
    }

    @MainActor
    private func scheduleExpiryCheck(for session: Session) {
        sessionExpiryTask?.cancel()
        let secondsUntilRefreshBoundary = AuthSessionTransitionGuard.expiryCheckDelay(
            expiresAt: session.expiresAt,
            now: Date().timeIntervalSince1970
        )
        let nanoseconds = UInt64(secondsUntilRefreshBoundary * 1_000_000_000)

        sessionExpiryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.handleSessionRefreshBoundary(for: session.user.id)
        }
    }

    /// 만료된 오프라인 세션은 간격을 늘려 가며 갱신을 다시 시도합니다.
    @MainActor
    private func scheduleOfflineRefreshRetry(for userID: UUID) {
        sessionExpiryTask?.cancel()
        let delay = AuthSessionTransitionGuard.offlineRefreshRetryDelay(afterFailures: offlineRefreshFailures)
        offlineRefreshFailures += 1
        let nanoseconds = UInt64(delay * 1_000_000_000)

        sessionExpiryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.handleSessionRefreshBoundary(for: userID)
        }
    }

    @MainActor
    private func handleSessionRefreshBoundary(for userID: UUID) async {
        guard let session, session.user.id == userID else { return }
        guard session.isExpired else {
            // The device clock can move backwards while the timer is sleeping.
            scheduleExpiryCheck(for: session)
            return
        }

        switch accessState {
        case .authenticatedOnline, .authenticatedOfflineLimited:
            // checkSession이 갱신 성공, 일시 장애(오프라인 유지), 확정 무효(잠금)를 가릅니다.
            await checkSession()
        default:
            await lockInvalidSessionAndClearProviderCache()
        }
    }

    private func isDefinitiveInvalidSession(_ error: Error) -> Bool {
        if let validationError = error as? AuthValidationError {
            if case .identityMismatch = validationError {
                return true
            }
        }

        guard let authError = error as? AuthError else { return false }
        let invalidCodes: Set<ErrorCode> = [
            .badJWT,
            .invalidJWT,
            .noAuthorization,
            .refreshTokenAlreadyUsed,
            .refreshTokenNotFound,
            .sessionExpired,
            .sessionNotFound,
            .userBanned,
            .userNotFound,
        ]

        if invalidCodes.contains(authError.errorCode) {
            return true
        }
        if case .api(_, _, _, let response) = authError {
            return response.statusCode == 401 || response.statusCode == 403
        }
        return false
    }

    @MainActor
    private func exposeLocallyLockedSession() {
        session = nil
        startupCachedSession = nil
        accessState = deletionNoticeDefaults.integer(forKey: Self.localSessionLockKey) == 2
            ? .lockedInvalidSession : .signedOut
        isSessionLoaded = true
    }

    private func matchesCurrentProviderSession(_ candidate: Session) -> Bool {
        guard let current = supabase.auth.currentSession else { return false }
        return current.user.id == candidate.user.id && current.accessToken == candidate.accessToken
    }
    
    // MARK: - Apple Sign In (SwiftUI Support)
    
    func prepareAppleSignInRequest(_ request: ASAuthorizationAppleIDRequest) {
        guard !isSigningOut else { return }
        _ = sessionTransition.beginInteractiveSignIn()
        let nonce = randomNonceString()
        currentNonce = nonce
        signInFailed = false
        request.requestedScopes = [.email]
        request.nonce = sha256(nonce)
    }
    
    func handleAppleSignInResult(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let idTokenData = appleIDCredential.identityToken,
                  let idToken = String(data: idTokenData, encoding: .utf8),
                  let nonce = currentNonce,
                  let attempt = sessionTransition.interactiveGeneration else {
                if let attempt = sessionTransition.interactiveGeneration {
                    sessionTransition.finishInteractiveSignIn(attempt, succeeded: false)
                }
                currentNonce = nil
                isProcessing = false
                signInFailed = true
                return
            }
            
            Task {
                do {
                    let shouldProceed = await MainActor.run {
                        guard self.sessionTransition.interactiveGeneration == attempt else { return false }
                        self.isProcessing = true
                        return true
                    }
                    guard shouldProceed else { return }
                    let session = try await supabase.auth.signInWithIdToken(
                        credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
                    )
                    await MainActor.run {
                        guard self.sessionTransition.interactiveGeneration == attempt else { return }
                        guard self.matchesCurrentProviderSession(session) else {
                            self.sessionTransition.finishInteractiveSignIn(attempt, succeeded: false)
                            self.currentNonce = nil
                            self.isProcessing = false
                            self.signInFailed = true
                            return
                        }
                        guard self.sessionTransition.finishInteractiveSignIn(attempt, succeeded: true) else { return }
                        self.deletionNoticeDefaults.removeObject(forKey: Self.localSessionLockKey)
                        self.acceptAuthenticatedSession(session, isOnline: true)
                        self.currentNonce = nil
                        self.isProcessing = false
                        self.signInFailed = false
                    }
                    print("apple_sign_in_succeeded")
                } catch {
                    print("apple_sign_in_exchange_failed")
                    await MainActor.run {
                        guard self.sessionTransition.finishInteractiveSignIn(attempt, succeeded: false) else { return }
                        self.currentNonce = nil
                        self.isProcessing = false
                        self.signInFailed = true
                    }
                }
            }
        case .failure(let error):
            if let attempt = sessionTransition.interactiveGeneration {
                sessionTransition.finishInteractiveSignIn(attempt, succeeded: false)
            }
            currentNonce = nil
            isProcessing = false
            signInFailed = (error as? ASAuthorizationError)?.code != .canceled
            print("apple_sign_in_failed")
        }
    }
    
    // Legacy support for non-SwiftUI cases if needed
    func startAppleSignIn() {
        guard !isSigningOut else { return }
        _ = sessionTransition.beginInteractiveSignIn()
        let nonce = randomNonceString()
        currentNonce = nonce
        
        let appleIDProvider = ASAuthorizationAppleIDProvider()
        let request = appleIDProvider.createRequest()
        signInFailed = false
        request.requestedScopes = [.email]
        request.nonce = sha256(nonce)
        
        let authorizationController = ASAuthorizationController(authorizationRequests: [request])
        authorizationController.delegate = self
        authorizationController.presentationContextProvider = self
        authorizationController.performRequests()
    }
    
    private func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        var randomBytes = [UInt8](repeating: 0, count: length)
        let errorCode = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        if errorCode != errSecSuccess {
            fatalError("Unable to generate nonce. SecRandomCopyBytes failed with OSStatus \(errorCode)")
        }
        
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        let nonce = randomBytes.map { charset[Int($0) % charset.count] }
        return String(nonce)
    }
    
    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashedData = SHA256.hash(data: inputData)
        let hashString = hashedData.compactMap { String(format: "%02x", $0) }.joined()
        return hashString
    }
}

extension AuthManager: ASAuthorizationControllerDelegate {
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        handleAppleSignInResult(.success(authorization))
    }
    
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        handleAppleSignInResult(.failure(error))
    }
}

extension AuthManager: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first!
        return scene.windows.first { $0.isKeyWindow } ?? UIWindow(windowScene: scene)
    }
}
