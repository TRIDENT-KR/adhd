import Testing
import Foundation
import SwiftData
import Supabase
@testable import ADHD

// MARK: - TaskManager.insertAndSave Tests (QA-008)
/// 수동 추가는 저장이 확정됐을 때만 성공으로 취급해야 한다
@MainActor
struct InsertAndSaveTests {

    private func makeManager() throws -> TaskManager {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: AppTask.self, configurations: config)
        let manager = TaskManager()
        manager.modelContext = ModelContext(container)
        return manager
    }

    @Test func savedTaskReturnsTrueAndPersists() throws {
        let manager = try makeManager()
        let task = AppTask(task: "약 먹기", category: "Routine")

        #expect(manager.insertAndSave(task))
        #expect(manager.modelContext?.hasChanges == false)
        #expect(manager.taskCount() == 1)
    }

    @Test func missingContextReturnsFalse() {
        let manager = TaskManager()
        manager.modelContext = nil

        #expect(!manager.insertAndSave(AppTask(task: "약 먹기", category: "Routine")))
        #expect(!manager.safeSave())
    }
}

// MARK: - CloudLLMManager.makeAnalyzePayload Tests (QA-006)
/// 서버 hash에 들어가는 입력은 논리 요청 하나당 한 번만 정해진다
struct AnalyzePayloadTests {

    @Test func payloadCarriesFixedMinuteAndLowercasedID() throws {
        let id = UUID()
        let now = try #require(Calendar.current.date(from: DateComponents(
            year: 2026, month: 9, day: 24, hour: 9, minute: 0, second: 59)))

        let payload = CloudLLMManager.makeAnalyzePayload(requestID: id, text: "내일 3시 병원", now: now, language: "ko")

        #expect(payload["requestId"] == id.uuidString.lowercased())
        #expect(payload["currentTime"] == "2026-09-24 09:00")
        #expect(payload["language"] == "ko")
        #expect(payload["text"] == "내일 3시 병원")
    }
}

// The transport is intercepted locally: no real account, API call or credential is used.
nonisolated private final class TokenEchoURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = try! JSONSerialization.data(withJSONObject: [
            "authorization": request.value(forHTTPHeaderField: "Authorization") ?? ""
        ])
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
struct FixedAccountRequestTests {
    private struct Echo: Decodable { let authorization: String }

    @Test func functionsAndRPCUseTheCapturedAccountToken() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TokenEchoURLProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }
        let first = SupabaseConfig.requestClient(accessToken: "fake-account-a", session: transport)
        let second = SupabaseConfig.requestClient(accessToken: "fake-account-b", session: transport)
        let secondResponse: Echo = try await second.functions.invoke("token-echo")
        let firstResponse: Echo = try await first.functions.invoke("token-echo")
        let rpc: PostgrestResponse<Echo> = try await first.rpc("token_echo").execute()
        #expect(secondResponse.authorization == "Bearer fake-account-b")
        #expect(firstResponse.authorization == "Bearer fake-account-a")
        #expect(rpc.value.authorization == "Bearer fake-account-a")
    }
}
