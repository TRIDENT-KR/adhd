import Testing
import Foundation
@testable import ADHD

// MARK: - Urgency Classification Tests
/// 하이브리드 urgency 분류 파이프라인 검증:
/// 1) LLM 응답의 urgency 필드 디코딩
/// 2) 필드 부재/이상값 시 카테고리 휴리스틱 (Appointment=strong, Routine=weak)
/// 3) 알림 파생 id 규약 (팔로업/스누즈)
@MainActor
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

// MARK: - 오늘 미리 완료한 반복 태스크의 알림 건너뛰기

@MainActor
struct SkipTodayPlanTests {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return cal
    }

    /// 2026-10-28(수) 지정 시각
    private func wednesday(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: hour, minute: minute))!
    }

    private func plan(rule: String?, anchor: Date?, fireDate: Date, hour: Int, now: Date, lead: Int = 0) -> SkipTodayPlan? {
        NotificationManager.skipTodayPlan(
            recurrenceRule: rule, anchor: anchor, fireDate: fireDate,
            hour: hour, minute: 0, leadMinutes: lead, now: now, calendar: calendar
        )
    }

    @Test func dailyRoutineCompletedBeforeTodaysAlarmSkipsOnlyToday() {
        // 20:30에 21:00 루틴 완료 → 수요일(4)만 빼고 매주 반복
        guard case .otherWeekdays(let weekdays) = plan(rule: nil, anchor: nil, fireDate: wednesday(21), hour: 21, now: wednesday(20, 30)) else {
            Issue.record("expected otherWeekdays"); return
        }
        #expect(weekdays == [1, 2, 3, 5, 6, 7])
    }

    @Test func dailyRoutineCompletedAfterTodaysAlarmKeepsNormalRepeat() {
        #expect(plan(rule: nil, anchor: nil, fireDate: wednesday(9), hour: 9, now: wednesday(10)) == nil)
    }

    @Test func leadTimeAlreadyPassedKeepsNormalRepeat() {
        // 21:00 루틴, 10분 전 알림(20:50)이 이미 지난 20:55에 완료
        #expect(plan(rule: nil, anchor: nil, fireDate: wednesday(20, 50), hour: 21, now: wednesday(20, 55), lead: 10) == nil)
    }

    @Test func weeklyCompletedOnItsDaySchedulesNextWeekOnce() {
        let anchor = calendar.date(byAdding: .day, value: -14, to: wednesday(0))!
        guard case .nextWeek(let date) = plan(rule: "weekly", anchor: anchor, fireDate: wednesday(19), hour: 19, now: wednesday(8)) else {
            Issue.record("expected nextWeek"); return
        }
        #expect(date == calendar.date(byAdding: .day, value: 7, to: wednesday(19)))
    }

    @Test func weeklyOnAnotherWeekdayOrNotStartedKeepsNormalRepeat() {
        let thursdayFire = calendar.date(byAdding: .day, value: 1, to: wednesday(19))!
        #expect(plan(rule: "weekly", anchor: thursdayFire, fireDate: thursdayFire, hour: 19, now: wednesday(8)) == nil)
        let futureAnchor = calendar.date(byAdding: .day, value: 7, to: wednesday(0))!
        #expect(plan(rule: "weekly", anchor: futureAnchor, fireDate: wednesday(19), hour: 19, now: wednesday(8)) == nil)
    }

    @Test func skipIdentifiersAreSeparateFromFollowUps() {
        let skipIDs = NotificationManager.skipDayIdentifiers(for: "ABC")
        #expect(skipIDs.count == 7)
        #expect(Set(skipIDs).isDisjoint(with: NotificationManager.followUpIdentifiers(for: "ABC")))
    }
}
