import Testing
import Foundation
import SwiftData
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
