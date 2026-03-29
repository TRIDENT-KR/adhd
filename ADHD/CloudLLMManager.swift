import Foundation
import SwiftUI
import Combine
import Supabase

struct AnalyzePayload: Codable {
    let text: String
    let currentTime: String
}

class CloudLLMManager: ObservableObject {
    @Published var isProcessing = false

    /// 최대 재시도 횟수
    private static let maxRetries = 3
    /// 요청 당 타임아웃 (초)
    private static let requestTimeout: TimeInterval = 15

    func analyzeText(text: String) async throws -> [LLMFunctionCall] {
        await MainActor.run { self.isProcessing = true }
        defer { Task { @MainActor in self.isProcessing = false } }

        var lastError: Error?

        for attempt in 0..<Self.maxRetries {
            do {
                let intents = try await withThrowingTaskGroup(of: [LLMFunctionCall].self) { group in
                    // API 호출 태스크
                    group.addTask {
                        let formatter = DateFormatter()
                        formatter.dateFormat = "yyyy-MM-dd HH:mm"
                        formatter.locale = Locale(identifier: "ko_KR")
                        let currentTimeString = formatter.string(from: Date())
                        
                        let payload = AnalyzePayload(text: text, currentTime: currentTimeString)

                        var headers: [String: String] = [:]
                        if let session = try? await supabase.auth.session {
                            headers["Authorization"] = "Bearer \(session.accessToken)"
                        }

                        let options = FunctionInvokeOptions(headers: headers, body: payload)
                        let result: [LLMFunctionCall] = try await supabase.functions.invoke("analyze-task", options: options)
                        return result
                    }

                    // 타임아웃 태스크
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(Self.requestTimeout * 1_000_000_000))
                        throw NSError(domain: "CloudLLM", code: 408,
                                      userInfo: [NSLocalizedDescriptionKey: "Request timed out after \(Int(Self.requestTimeout))s"])
                    }

                    // 먼저 완료된 쪽 결과 반환, 나머지 취소
                    let result = try await group.next()!
                    group.cancelAll()
                    return result
                }
                return intents
            } catch {
                lastError = error
                print("⚠️ API 시도 \(attempt + 1)/\(Self.maxRetries) 실패: \(error.localizedDescription)")

                // 마지막 시도가 아니면 지수 백오프 대기
                if attempt < Self.maxRetries - 1 {
                    let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000 // 1s, 2s, 4s
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }

        print("❌ Supabase Edge Function 최종 실패: \(lastError?.localizedDescription ?? "unknown")")
        throw NSError(
            domain: "CloudLLM",
            code: 500,
            userInfo: [NSLocalizedDescriptionKey: "Failed after \(Self.maxRetries) attempts: \(lastError?.localizedDescription ?? "unknown")"]
        )
    }
}
