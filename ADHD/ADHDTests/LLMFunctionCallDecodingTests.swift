import Testing
import Foundation
@testable import ADHD

// MARK: - LLMFunctionCall 디코딩 Tests
/// Gemini 응답 JSON → 함수 8종 라우팅 + 카테고리 정규화 + 편집 규약 검증
struct LLMFunctionCallDecodingTests {

    private func decode(_ json: String) throws -> LLMFunctionCall {
        try JSONDecoder().decode(LLMFunctionCall.self, from: Data(json.utf8))
    }

    // MARK: 함수 8종 라우팅

    @Test func decodesAddSingleTask() throws {
        let call = try decode(#"{"function_name":"add_single_task","parameters":{"task_name":"약 먹기","time":"09:00 AM","category":"Routine"}}"#)
        guard case .addSingleTask(let p) = call else { Issue.record("wrong case"); return }
        #expect(p.task_name == "약 먹기")
        #expect(p.time == "09:00 AM")
    }

    @Test func decodesUpdateTask() throws {
        let call = try decode(#"{"function_name":"update_task","parameters":{"target_task_name":"회의","new_time":"03:00 PM"}}"#)
        guard case .updateTask(let p) = call else { Issue.record("wrong case"); return }
        #expect(p.target_task_name == "회의")
        #expect(p.new_time == "03:00 PM")
    }

    @Test func decodesDeleteSpecificTask() throws {
        let call = try decode(#"{"function_name":"delete_specific_task","parameters":{"target_task_name":"운동"}}"#)
        guard case .deleteSpecificTask(let p) = call else { Issue.record("wrong case"); return }
        #expect(p.target_task_name == "운동")
    }

    @Test func decodesClearAllTasks() throws {
        let call = try decode(#"{"function_name":"clear_all_tasks","parameters":{"target_date":"all"}}"#)
        guard case .clearAllTasks(let p) = call else { Issue.record("wrong case"); return }
        #expect(p.target_date == "all")
    }

    @Test func decodesPostponeAllTasks() throws {
        let call = try decode(#"{"function_name":"postpone_all_tasks","parameters":{"from_date":"2026-07-09","to_date":"2026-07-10"}}"#)
        guard case .postponeAllTasks(let p) = call else { Issue.record("wrong case"); return }
        #expect(p.from_date == "2026-07-09")
        #expect(p.to_date == "2026-07-10")
    }

    @Test func decodesMarkTaskComplete() throws {
        let call = try decode(#"{"function_name":"mark_task_complete","parameters":{"target_task_name":"물 마시기"}}"#)
        guard case .markTaskComplete(let p) = call else { Issue.record("wrong case"); return }
        #expect(p.target_task_name == "물 마시기")
    }

    @Test func decodesRequestClarification() throws {
        let call = try decode(#"{"function_name":"request_clarification","parameters":{"reason":"시간이 모호합니다"}}"#)
        guard case .requestClarification(let p) = call else { Issue.record("wrong case"); return }
        #expect(p.reason == "시간이 모호합니다")
    }

    @Test func decodesHandleOffTopicChat() throws {
        let call = try decode(#"{"function_name":"handle_off_topic_chat","parameters":{"message":"저는 일정 관리를 도와드려요"}}"#)
        #expect(call.isOffTopic)
        #expect(call.offTopicMessage == "저는 일정 관리를 도와드려요")
    }

    @Test func unknownFunctionFallsBackToUnknownCase() throws {
        let call = try decode(#"{"function_name":"launch_rocket","parameters":{}}"#)
        guard case .unknown(let name) = call else { Issue.record("wrong case"); return }
        #expect(name == "launch_rocket")
    }

    // MARK: 카테고리 정규화 (대소문자·이상값 방어)

    @Test func normalizesLowercaseAppointment() throws {
        let call = try decode(#"{"function_name":"add_single_task","parameters":{"task_name":"치과","category":"appointment"}}"#)
        guard case .addSingleTask(let p) = call else { Issue.record("wrong case"); return }
        #expect(p.category == "Appointment")
    }

    @Test func normalizesUnknownCategoryToRoutine() throws {
        let call = try decode(#"{"function_name":"add_single_task","parameters":{"task_name":"x","category":"banana"}}"#)
        guard case .addSingleTask(let p) = call else { Issue.record("wrong case"); return }
        #expect(p.category == "Routine")
    }

    @Test func normalizesUpdateTaskNewCategory() throws {
        let call = try decode(#"{"function_name":"update_task","parameters":{"target_task_name":"x","new_category":"APPOINTMENT"}}"#)
        guard case .updateTask(let p) = call else { Issue.record("wrong case"); return }
        #expect(p.new_category == "Appointment")
    }

    // MARK: updateFields — Routine 전환 시 date nil 강제

    @Test func updateFieldsForcesNilDateForRoutine() throws {
        var call = try decode(#"{"function_name":"add_single_task","parameters":{"task_name":"x","date":"2026-07-10","category":"Appointment"}}"#)
        call.updateFields(taskName: "x", time: "09:00 AM", date: "2026-07-10", category: "Routine")
        guard case .addSingleTask(let p) = call else { Issue.record("wrong case"); return }
        #expect(p.date == nil)          // 루틴은 매일 반복 — 날짜 정보 금지 규약
        #expect(p.category == "Routine")
    }
}
