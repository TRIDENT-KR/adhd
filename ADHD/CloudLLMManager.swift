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
    case quotaExhausted
    case authenticationRequired
    case requestRejected
    case serverUnavailable
    case invalidResponse
}

class CloudLLMManager: ObservableObject {
    @Published var isProcessing = false
    @Published private(set) var latestQuota: ServerAIQuotaSnapshot?

    /// 최대 재시도 횟수
    private static let maxRetries = 5
    /// 요청 당 타임아웃 (초)
    private static let requestTimeout: TimeInterval = 15

    func analyzeText(text: String) async throws -> [LLMFunctionCall] {
        await MainActor.run { self.isProcessing = true }
        defer { Task { @MainActor in self.isProcessing = false } }

        let maxRetries = Self.maxRetries
        let timeout = Self.requestTimeout
        // 한 번의 사용자 분석 탭에 하나만 만들고, 네트워크 재시도에는 같은 ID를 사용합니다.
        // 서버 원장이 이 ID로 중복 차감과 서로 다른 입력 재사용을 차단합니다.
        let logicalRequestID = UUID()

        var lastError: Error?
        for attempt in 0..<maxRetries {
            try Task.checkCancellation()
            do {
                // Main-actor-isolated 값을 task group 밖에서 캡처
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH:mm"
                formatter.locale = Locale(identifier: "ko_KR")
                let currentTimeString = formatter.string(from: Date())
                let currentLanguage = await MainActor.run { LocalizationManager.shared.currentLanguage.rawValue }

                let payload: [String: String] = [
                    "requestId": logicalRequestID.uuidString.lowercased(),
                    "text": text,
                    "currentTime": currentTimeString,
                    "language": currentLanguage
                ]

                let response = try await withThrowingTaskGroup(of: AnalyzeTaskResponse.self) { group in
                    // API 호출 태스크
                    group.addTask {
                        var headers: [String: String] = [:]
                        if let session = try? await supabase.auth.session {
                            headers["Authorization"] = "Bearer \(session.accessToken)"
                        }

                        let options = FunctionInvokeOptions(headers: headers, body: payload)
                        let result: AnalyzeTaskResponse = try await supabase.functions.invoke(
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
                guard response.requestId == logicalRequestID,
                      response.quota.isValid,
                      !response.calls.isEmpty,
                      response.calls.allSatisfy(\.isExecutionPayloadValid) else {
                    throw CloudLLMError.invalidResponse
                }
                await MainActor.run { self.latestQuota = response.quota }
                return response.calls
            } catch {
                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                lastError = error
                print("ai_request_attempt_failed attempt=\(attempt + 1) max=\(maxRetries)")

                guard shouldRetry(error) else {
                    throw mappedError(error)
                }

                // 마지막 시도가 아니면 지수 백오프 대기
                if attempt < maxRetries - 1 {
                    let seconds = min(4, Int(pow(2.0, Double(attempt))))
                    let delay = UInt64(seconds) * 1_000_000_000
                    try await Task.sleep(nanoseconds: delay)
                }
            }
        }

        print("ai_request_failed attempts=\(maxRetries)")
        throw mappedError(lastError ?? CloudLLMError.serverUnavailable)
    }

    private func shouldRetry(_ error: Error) -> Bool {
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
            let code = structuredErrorCode(from: data)
            if code == "analysis_in_progress" { return true }
            if status == 503 { return true }
            if status == 502 {
                return code == "gemini_request_failed" || code == "analysis_failed"
            }
            return false
        }
    }

    private func mappedError(_ error: Error) -> CloudLLMError {
        if let cloudError = error as? CloudLLMError { return cloudError }
        guard let functionsError = error as? FunctionsError else {
            return error is DecodingError ? .invalidResponse : .serverUnavailable
        }

        switch functionsError {
        case .relayError:
            return .serverUnavailable
        case .httpError(let status, let data):
            let code = structuredErrorCode(from: data)
            if code == "quota_exhausted" || status == 429 {
                return .quotaExhausted
            }
            if status == 401 || status == 403 {
                return .authenticationRequired
            }
            if status == 400 || status == 409 {
                return .requestRejected
            }
            return .serverUnavailable
        }
    }

    private func structuredErrorCode(from data: Data) -> String? {
        try? JSONDecoder().decode(AnalyzeTaskErrorResponse.self, from: data).error.code
    }
}
