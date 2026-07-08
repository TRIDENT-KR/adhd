import Testing
import Foundation
@testable import ADHD

// MARK: - Urgency Classification Tests
/// 하이브리드 urgency 분류 파이프라인 검증:
/// 1) LLM 응답의 urgency 필드 디코딩
/// 2) 필드 부재/이상값 시 카테고리 휴리스틱 (Appointment=strong, Routine=weak)
/// 3) 알림 파생 id 규약 (팔로업/스누즈)
struct UrgencyClassificationTests {

    // MARK: - Helpers

    private func decode(_ json: String) throws -> LLMFunctionCall {
        try JSONDecoder().decode(LLMFunctionCall.self, from: Data(json.utf8))
    }

    private func addTaskJSON(category: String, urgency: String?) -> String {
        let urgencyField: String
        if let urgency {
            urgencyField = "\"urgency\": \"\(urgency)\","
        } else {
            urgencyField = ""
        }
        return """
        {
          "function_name": "add_single_task",
          "parameters": {
            "task_name": "테스트 태스크",
            "time": "09:00 AM",
            "date": null,
            "category": "\(category)",
            "recurrence": null,
            \(urgencyField)
            "task_note": null
          }
        }
        """
    }

    // MARK: - LLM urgency 디코딩

    @Test func llmStrongIsAdopted() throws {
        // Routine인데 LLM이 strong이라고 판단 → LLM 값이 휴리스틱을 이김
        let call = try decode(addTaskJSON(category: "Routine", urgency: "strong"))
        #expect(PendingLLMCall(call: call).urgency == .strong)
    }

    @Test func llmWeakIsAdopted() throws {
        // Appointment인데 LLM이 weak이라고 판단 → LLM 값이 휴리스틱을 이김
        let call = try decode(addTaskJSON(category: "Appointment", urgency: "weak"))
        #expect(PendingLLMCall(call: call).urgency == .weak)
    }

    // MARK: - 휴리스틱 폴백 (urgency 부재)

    @Test func missingUrgencyAppointmentDefaultsToStrong() throws {
        let call = try decode(addTaskJSON(category: "Appointment", urgency: nil))
        #expect(PendingLLMCall(call: call).urgency == .strong)
    }

    @Test func missingUrgencyRoutineDefaultsToWeak() throws {
        let call = try decode(addTaskJSON(category: "Routine", urgency: nil))
        #expect(PendingLLMCall(call: call).urgency == .weak)
    }

    @Test func invalidUrgencyFallsBackToHeuristic() throws {
        // 화이트리스트 외 값("urgent")은 서버에서 null 처리되지만, 뚫고 와도 휴리스틱으로 폴백
        let call = try decode(addTaskJSON(category: "Routine", urgency: "urgent"))
        #expect(PendingLLMCall(call: call).urgency == .weak)
    }

    @Test func categoryNormalizationStillApplies() throws {
        // 소문자 "appointment" → "Appointment" 정규화 후 휴리스틱 적용
        let call = try decode(addTaskJSON(category: "appointment", urgency: nil))
        #expect(PendingLLMCall(call: call).urgency == .strong)
    }

    // MARK: - add 이외 함수콜

    @Test func nonAddCallsDefaultToStrong() throws {
        let json = """
        {
          "function_name": "delete_specific_task",
          "parameters": { "target_task_name": "운동", "target_category": "all", "target_date": "all" }
        }
        """
        let call = try decode(json)
        #expect(PendingLLMCall(call: call).urgency == .strong)
    }

    // MARK: - 파생 알림 id 규약

    @Test func followUpIdentifierConvention() {
        let ids = NotificationManager.followUpIdentifiers(for: "ABC-123")
        #expect(ids == ["ABC-123-f1", "ABC-123-f2", "ABC-123-snooze"])
    }
}
