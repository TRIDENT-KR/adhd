import Foundation
import SwiftUI
import Combine
import Supabase

struct ServerAIQuotaSnapshot: Decodable, Equatable {
    let isPro: Bool
    let limit: Int?
    let used: Int
    let reserved: Int
    let remaining: Int?
    let usageDate: String
    let timeZone: String

    var isValid: Bool {
        guard used >= 0,
              reserved >= 0,
              timeZone == "Asia/Seoul",
              Self.isValidDate(usageDate) else { return false }
        if isPro {
            return limit == nil && remaining == nil
        }
        guard limit == SubscriptionManager.freeAILimit,
              let remaining,
              (0...SubscriptionManager.freeAILimit).contains(remaining) else {
            return false
        }
        return used + reserved + remaining == SubscriptionManager.freeAILimit
    }

    private static func isValidDate(_ value: String) -> Bool {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }
}

private struct AnalyzeTaskResponse: Decodable {
    let requestId: UUID
    let calls: [LLMFunctionCall]
    let quota: ServerAIQuotaSnapshot
}

private struct AnalyzeTaskErrorResponse: Decodable {
    struct ErrorBody: Decodable {
        let code: String
    }

    let error: ErrorBody
    let requestId: UUID?
}

enum CloudLLMError: Error, Equatable {
    case adultEligibilityRequired
    case consentRequired
    /// 무료 일일 한도를 다 쓴 경우에만 사용합니다. 이 오류만 결제 화면으로 안내합니다.
    case quotaExhausted
    /// 분당 요청 제한이나 같은 요청의 재시도 한도에 걸린 경우입니다. 잠시 뒤 다시 시도하면 됩니다.
    case rateLimited
    case authenticationRequired
    case requestRejected
    case serverUnavailable
    case invalidResponse
    /// 기기가 인터넷에 연결되지 않음
    case offline
    /// 초안이 서버 한도(1,000자)를 넘음
    case inputTooLong
}

class CloudLLMManager: ObservableObject {
    @Published var isProcessing = false
    @Published private(set) var latestQuota: ServerAIQuotaSnapshot?

    /// 같은 requestId로 보내는 최대 시도 횟수.
    /// 서버 원장은 requestId 하나에 3번까지만 예약을 허용하므로(request_replay_limit) 같은 값으로 맞춥니다.
    static let maxAttempts = 3
    /// 요청 당 타임아웃 (초)
    private static let requestTimeout: TimeInterval = 15
    /// 사용자가 기다리는 전체 시간 상한 (초). 재시도와 그 사이 대기를 모두 포함합니다.
    static let totalDeadline: TimeInterval = 30
    /// 남은 시간이 이보다 짧으면 새 시도를 시작하지 않습니다.
    private static let minimumAttemptTime: TimeInterval = 3

    /// 이번 시도에 쓸 타임아웃. 전체 상한을 넘기지 않도록 줄이고, 남은 시간이 너무 짧으면 nil입니다.
    static func attemptTimeout(elapsed: TimeInterval) -> TimeInterval? {
        let remaining = totalDeadline - elapsed
        guard remaining >= minimumAttemptTime else { return nil }
        return min(requestTimeout, remaining)
    }

    func analyzeText(text: String) async throws -> [LLMFunctionCall] {
        guard let consentScope = AccountPreferences.activeScope,
              AIDataConsent.isGranted() else { throw CloudLLMError.consentRequired }

        await MainActor.run { self.isProcessing = true }
        defer { Task { @MainActor in self.isProcessing = false } }

        let maxAttempts = Self.maxAttempts
        let startedAt = Date()
        // 한 번의 사용자 분석 탭에 하나만 만들고, 네트워크 재시도에는 같은 ID를 사용합니다.
        // 서버 원장이 이 ID로 중복 차감과 서로 다른 입력 재사용을 차단합니다.
        let logicalRequestID = UUID()
        // 서버는 requestId와 함께 입력 전체(시간·언어 포함)를 hash로 묶습니다.
        // 재시도 중 분이 바뀌거나 언어가 바뀌어도 같은 요청으로 인정받도록 payload를 한 번만 만듭니다.
        let currentLanguage = await MainActor.run { LocalizationManager.shared.currentLanguage.rawValue }
        let payload = Self.makeAnalyzePayload(
            requestID: logicalRequestID,
            text: text,
            now: Date(),
            language: currentLanguage
        )

        var lastError: Error?
        for attempt in 0..<maxAttempts {
            try Task.checkCancellation()
            guard AccountPreferences.activeScope == consentScope,
                  AIDataConsent.isGranted() else { throw CloudLLMError.consentRequired }
            // 재시도까지 합쳐 30초를 넘기지 않습니다(지하철 등에서 오래 붙잡지 않게).
            guard let timeout = Self.attemptTimeout(elapsed: Date().timeIntervalSince(startedAt)) else { break }

            do {
                let response = try await withThrowingTaskGroup(of: AnalyzeTaskResponse.self) { group in
                    // API 호출 태스크
                    group.addTask { @MainActor in
                        let session = try await supabase.auth.session
                        try Task.checkCancellation()
                        guard AccountPreferences.activeScope == consentScope,
                              AccountPreferences.scope(for: session.user.id) == consentScope,
                              AIDataConsent.isGranted(for: session.user.id) else {
                            throw CloudLLMError.consentRequired
                        }
                        try await AdultEligibilityManager.shared.requireServerEligibility(
                            userID: session.user.id, accessToken: session.accessToken
                        )
                        try Task.checkCancellation()
                        guard AccountPreferences.activeScope == consentScope,
                              AIDataConsent.isGranted(for: session.user.id) else {
                            throw CloudLLMError.consentRequired
                        }
                        let requestClient = SupabaseConfig.requestClient(accessToken: session.accessToken)
                        let options = FunctionInvokeOptions(body: payload)
                        let result: AnalyzeTaskResponse = try await requestClient.functions.invoke(
                            "analyze-task",
                            options: options
                        )
                        return result
                    }

                    // 타임아웃 태스크
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                        throw NSError(domain: "CloudLLM", code: 408,
                                      userInfo: [NSLocalizedDescriptionKey: "Request timed out after \(Int(timeout))s"])
                    }

                    // 먼저 완료된 쪽 결과 반환, 나머지 취소
                    let result = try await group.next()!
                    group.cancelAll()
                    return result
                }
                try Task.checkCancellation()
                guard AccountPreferences.activeScope == consentScope,
                      AIDataConsent.isGranted() else { throw CloudLLMError.consentRequired }
                // 항목별 실행 가능 여부는 화면에서 걸러 냅니다. 서버가 검증·차감한 응답을 통째로 버리지 않습니다.
                guard response.requestId == logicalRequestID,
                      response.quota.isValid,
                      !response.calls.isEmpty else {
                    throw CloudLLMError.invalidResponse
                }
                await MainActor.run { self.latestQuota = response.quota }
                return response.calls
            } catch {
                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                lastError = error
                print("ai_request_attempt_failed attempt=\(attempt + 1) max=\(maxAttempts)")

                guard shouldRetry(error) else {
                    throw mappedError(error)
                }

                // 마지막 시도가 아니면 지수 백오프 대기
                if attempt < maxAttempts - 1 {
                    let seconds = min(4, Int(pow(2.0, Double(attempt))))
                    // 대기 뒤 남은 시간이 없으면 기다리지 않고 바로 끝냅니다.
                    guard Self.attemptTimeout(elapsed: Date().timeIntervalSince(startedAt) + Double(seconds)) != nil else { break }
                    let delay = UInt64(seconds) * 1_000_000_000
                    try await Task.sleep(nanoseconds: delay)
                }
            }
        }

        print("ai_request_failed attempts=\(maxAttempts)")
        throw mappedError(lastError ?? CloudLLMError.serverUnavailable)
    }

    /// 논리 요청 하나에 대응하는 analyze-task 입력. 재시도 동안 절대 다시 만들지 않습니다.
    static func makeAnalyzePayload(requestID: UUID, text: String, now: Date, language: String) -> [String: String] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.locale = Locale(identifier: "ko_KR")
        return [
            "requestId": requestID.uuidString.lowercased(),
            "text": text,
            "currentTime": formatter.string(from: now),
            "language": language
        ]
    }

    private func shouldRetry(_ error: Error) -> Bool {
        if error is AdultEligibilityError { return false }
        if let cloudError = error as? CloudLLMError {
            return cloudError == .serverUnavailable
        }
        if let urlError = error as? URLError {
            return [
                .timedOut,
                .networkConnectionLost,
                .notConnectedToInternet,
                .cannotConnectToHost,
                .dnsLookupFailed,
            ].contains(urlError.code)
        }
        let nsError = error as NSError
        if nsError.domain == "CloudLLM", nsError.code == 408 { return true }

        guard let functionsError = error as? FunctionsError else { return false }
        switch functionsError {
        case .relayError:
            return true
        case .httpError(let status, let data):
            return Self.isRetryableHTTPFailure(status: status, code: structuredErrorCode(from: data))
        }
    }

    /// 서버가 같은 requestId로 다시 시도해도 된다고 표시한 실패만 자동 재시도합니다.
    /// 429(한도·요청 제한)는 바로 다시 보내도 같은 결과이므로 재시도하지 않습니다.
    static func isRetryableHTTPFailure(status: Int, code: String?) -> Bool {
        if code == "analysis_in_progress" { return true }
        if status == 503 { return true }
        if status == 502 {
            return code == "gemini_request_failed"
                || code == "gemini_network_failed"
                || code == "analysis_failed"
        }
        return false
    }

    private func mappedError(_ error: Error) -> CloudLLMError {
        if let error = error as? AdultEligibilityError {
            return error == .unavailable ? .serverUnavailable : .adultEligibilityRequired
        }
        if let cloudError = error as? CloudLLMError { return cloudError }
        if let urlError = error as? URLError, Self.isOfflineError(urlError.code) { return .offline }
        guard let functionsError = error as? FunctionsError else {
            return error is DecodingError ? .invalidResponse : .serverUnavailable
        }

        switch functionsError {
        case .relayError:
            return .serverUnavailable
        case .httpError(let status, let data):
            return Self.mappedHTTPError(status: status, code: structuredErrorCode(from: data))
        }
    }

    /// 서버 HTTP 오류를 화면 동작으로 바꿉니다.
    /// 결제 화면은 quota_exhausted일 때만 열고, 다른 429(rate_limited·request_replay_limit)는
    /// Pro 사용자에게도 생길 수 있으므로 잠시 뒤 다시 시도하라는 안내로 보냅니다.
    static func mappedHTTPError(status: Int, code: String?) -> CloudLLMError {
        if code == "adult_eligibility_required" { return .adultEligibilityRequired }
        if code == "quota_exhausted" { return .quotaExhausted }
        if code == "input_too_long" { return .inputTooLong }
        if status == 429 { return .rateLimited }
        if status == 401 || status == 403 {
            return .authenticationRequired
        }
        if status == 400 || status == 409 {
            return .requestRejected
        }
        return .serverUnavailable
    }

    static func isOfflineError(_ code: URLError.Code) -> Bool {
        [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff]
            .contains(code)
    }

    private func structuredErrorCode(from data: Data) -> String? {
        try? JSONDecoder().decode(AnalyzeTaskErrorResponse.self, from: data).error.code
    }
}

struct AIDataConsentView: View {
    let userID: UUID?
    var onAllowed: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(L.aiPrivacy.explanation)
                    Text(L.aiPrivacy.choice)
                    Link(L.settings.privacyPolicy, destination: URL(string: "https://trident-kr.github.io/waitwhat-site/privacy/")!)
                    Link(L.aiPrivacy.googlePolicy, destination: URL(string: "https://ai.google.dev/gemini-api/terms")!)
                    Button(L.aiPrivacy.allow) {
                        guard let userID,
                              AccountPreferences.activeScope == AccountPreferences.scope(for: userID) else { return }
                        AIDataConsent.setGranted(true, for: userID)
                        dismiss()
                        onAllowed()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(userID == nil)
                    Button(L.aiPrivacy.notNow) { dismiss() }
                        .frame(minHeight: 44)
                }
                .padding(24)
            }
            .background(DesignSystem.Colors.background)
            .navigationTitle(L.aiPrivacy.title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(DesignSystem.Colors.primary)
    }
}
