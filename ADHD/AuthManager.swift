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
            return "인터넷에 연결한 뒤 다시 시도해 주세요."
        case .appleCredentialMissing:
            return "Apple 재인증 정보를 받지 못했습니다. 다시 시도해 주세요."
        case .appleAccountMismatch:
            return "현재 Mora 계정과 같은 Apple 계정으로 인증해 주세요."
        case .appleReauthenticationRequired:
            return "Apple로 다시 인증해야 삭제를 계속할 수 있습니다."
        case .invalidServerResponse, .statusUnavailable:
            return "삭제 상태를 확인하지 못했습니다. 요청 ID와 함께 고객 지원에 문의해 주세요."
        }
    }
}

private struct AccountDeletionEnvelope: Codable {
    let requestId: UUID
    let jobId: UUID
    let status: AccountDeletionProgressStatus
    let statusToken: String?
}

private struct AccountDeletionServerError: Decodable {
    struct Detail: Decodable { let code: String }
    let error: Detail
    let requestId: UUID?
    let jobId: UUID?
    let status: AccountDeletionProgressStatus?
    let statusToken: String?
}

private struct PendingAccountDeletion: Codable {
    let userID: UUID
    let requestID: UUID
    var jobID: UUID?
    var status: AccountDeletionProgressStatus
    var statusToken: String?
    var needsAppleReauthentication: Bool
}

private struct AccountDeletionPollingStore {
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

    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
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
    private var deletionPollingTask: Task<Void, Never>?
    private let deletionPollingStore = AccountDeletionPollingStore()

    override init() {
        let cachedSession = supabase.auth.currentSession
        startupCachedSession = cachedSession
        lastKnownUserID = cachedSession?.user.id
        super.init()

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
        let fallbackSession = session ?? supabase.auth.currentSession ?? startupCachedSession

        do {
            let refreshedSession = try await supabase.auth.session
            guard !refreshedSession.isExpired else {
                await lockInvalidSessionAndClearProviderCache()
                return
            }

            let currentUser = try await supabase.auth.user(jwt: refreshedSession.accessToken)
            guard currentUser.id == refreshedSession.user.id else {
                throw AuthValidationError.identityMismatch
            }
            acceptAuthenticatedSession(refreshedSession, isOnline: true)
        } catch {
            if isDefinitiveInvalidSession(error) {
                await lockInvalidSessionAndClearProviderCache()
            } else if let fallbackSession, !fallbackSession.isExpired {
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

    /// 네트워크 변화는 세션 유효성과 별도 상태로 관리합니다.
    @MainActor
    func handleConnectivityChange(isConnected: Bool) async {
        if let pending = deletionPollingStore.load() {
            exposePendingDeletion(pending)
            if isConnected { startDeletionPollingIfPossible() }
            return
        }
        if !isConnected {
            let fallbackSession = session ?? supabase.auth.currentSession ?? startupCachedSession
            if let fallbackSession, !fallbackSession.isExpired {
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
        lastKnownUserID = session?.user.id ?? accessState.accountUserID ?? lastKnownUserID
        session = nil
        startupCachedSession = nil
        sessionExpiryTask?.cancel()
        accessState = .signedOut
        isSessionLoaded = true

        do {
            try await supabase.auth.signOut()
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
        guard let pending = deletionPollingStore.load(),
              let statusToken = pending.statusToken else {
            accountDeletionNeedsAppleReauthentication = true
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
            accountDeletionErrorCode = decodeAccountDeletionServerError(error)?.error.code
                ?? "deletion_status_unavailable"
            throw error
        }
    }

    /// 동기 응답, polling 또는 auth userDeleted event가 실제 완료를 알릴 때의 단일 진입점입니다.
    @MainActor
    func confirmAccountDeletionCompleted(for userID: UUID) {
        deletionPollingTask?.cancel()
        deletionPollingTask = nil
        deletionPollingStore.clear()
        accountDeletionStatus = .completed
        accountDeletionRequestID = nil
        accountDeletionNeedsAppleReauthentication = false
        accountDeletionErrorCode = nil
        if accessState.accountUserID == userID || session?.user.id == userID {
            session = nil
            startupCachedSession = nil
            sessionExpiryTask?.cancel()
            accessState = .signedOut
            isSessionLoaded = true
        }
        if lastKnownUserID == userID {
            lastKnownUserID = nil
        }
        NotificationCenter.default.post(name: .moraAccountDeletionCompleted, object: userID)
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
        if let responseRequestID = response.requestId,
           responseRequestID != existing.requestID {
            throw AccountDeletionClientError.invalidServerResponse
        }

        var pending = existing
        pending.jobID = response.jobId ?? pending.jobID
        pending.status = response.status ?? .retryWait
        if let token = response.statusToken {
            guard token.count == 43 else {
                throw AccountDeletionClientError.invalidServerResponse
            }
            pending.statusToken = token
        }
        pending.needsAppleReauthentication = response.error.code == "apple_reauth_required"
        try deletionPollingStore.save(pending)
        accountDeletionErrorCode = response.error.code
        exposePendingDeletion(pending)
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
        guard let pending = deletionPollingStore.load(),
              pending.statusToken != nil,
              !pending.needsAppleReauthentication,
              pending.status != .completed else { return }

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
                    continue
                }
            }
        }
    }

    @MainActor
    private func acceptAuthenticatedSession(_ session: Session, isOnline: Bool) {
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
        scheduleExpiryCheck(for: session)
    }

    @MainActor
    private func lockInvalidSessionAndClearProviderCache() async {
        lastKnownUserID = session?.user.id ?? startupCachedSession?.user.id ?? lastKnownUserID
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
            if let session, !session.isExpired {
                acceptAuthenticatedSession(session, isOnline: true)
            } else {
                await lockInvalidSessionAndClearProviderCache()
            }

        case .signedOut:
            self.session = nil
            startupCachedSession = nil
            sessionExpiryTask?.cancel()
            if let pending = deletionPollingStore.load() {
                exposePendingDeletion(pending)
            } else if accessState != .signedOut {
                accessState = lastKnownUserID == nil ? .signedOut : .lockedInvalidSession
                isSessionLoaded = true
            }

        case .userDeleted:
            if let userID = session?.user.id ?? lastKnownUserID {
                confirmAccountDeletionCompleted(for: userID)
            }

        case .userUpdated:
            if let session,
               session.user.id == accessState.accountUserID,
               !session.isExpired {
                acceptAuthenticatedSession(session, isOnline: true)
            }

        case .passwordRecovery, .mfaChallengeVerified:
            break
        }
    }

    @MainActor
    private func scheduleExpiryCheck(for session: Session) {
        sessionExpiryTask?.cancel()
        let secondsUntilRefreshBoundary = max(
            0,
            session.expiresAt - Date().timeIntervalSince1970 - 30
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

    @MainActor
    private func handleSessionRefreshBoundary(for userID: UUID) async {
        guard session?.user.id == userID, session?.isExpired == true else { return }

        if case .authenticatedOnline = accessState {
            await checkSession()
        } else {
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
    
    // MARK: - Apple Sign In (SwiftUI Support)
    
    func prepareAppleSignInRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = randomNonceString()
        currentNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(nonce)
    }
    
    func handleAppleSignInResult(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let idTokenData = appleIDCredential.identityToken,
                  let idToken = String(data: idTokenData, encoding: .utf8),
                  let nonce = currentNonce else {
                print("❌ Apple Sign In failed: Missing credentials or nonce")
                return
            }
            
            Task {
                do {
                    await MainActor.run { self.isProcessing = true }
                    let session = try await supabase.auth.signInWithIdToken(
                        credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
                    )
                    await MainActor.run {
                        self.acceptAuthenticatedSession(session, isOnline: true)
                        self.currentNonce = nil
                        self.isProcessing = false
                    }
                    print("apple_sign_in_succeeded")
                } catch {
                    print("apple_sign_in_exchange_failed")
                    await MainActor.run {
                        self.currentNonce = nil
                        self.isProcessing = false
                    }
                }
            }
        case .failure:
            print("apple_sign_in_failed")
        }
    }
    
    // Legacy support for non-SwiftUI cases if needed
    func startAppleSignIn() {
        let nonce = randomNonceString()
        currentNonce = nonce
        
        let appleIDProvider = ASAuthorizationAppleIDProvider()
        let request = appleIDProvider.createRequest()
        request.requestedScopes = [.fullName, .email]
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
        guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let idTokenData = appleIDCredential.identityToken,
              let idToken = String(data: idTokenData, encoding: .utf8),
              let nonce = currentNonce else {
            print("❌ Apple Sign In failed: Missing credentials")
            return
        }
        
        Task {
            do {
                await MainActor.run { self.isProcessing = true }
                let session = try await supabase.auth.signInWithIdToken(
                    credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
                )
                await MainActor.run {
                    self.acceptAuthenticatedSession(session, isOnline: true)
                    self.currentNonce = nil
                    self.isProcessing = false
                }
                print("apple_sign_in_succeeded")
            } catch {
                print("apple_sign_in_exchange_failed")
                await MainActor.run {
                    self.currentNonce = nil
                    self.isProcessing = false
                }
            }
        }
    }
    
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        print("apple_sign_in_failed")
    }
}

extension AuthManager: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first!
        return scene.windows.first { $0.isKeyWindow } ?? UIWindow(windowScene: scene)
    }
}
