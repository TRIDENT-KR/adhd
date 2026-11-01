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
            urgencyField = "\"urgency\": \"\(urgency)\""
        } else {
            urgencyField = "\"urgency\": null"
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

    @Test func invalidUrgencyCannotExecuteEvenIfPreviewHasADefault() throws {
        // 표시용 기본값은 실행 허가가 아니다. 현재 서버·클라이언트 계약은 이상값을 거부한다.
        let call = try decode(addTaskJSON(category: "Routine", urgency: "urgent"))
        #expect(PendingLLMCall(call: call).urgency == .weak)
        #expect(!call.isExecutionPayloadValid)
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

// MARK: - 건너뛸 회차(오늘 미리 완료·이번만 건너뛰기)를 뺀 알림 예약

@MainActor
struct SkipPlanTests {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return cal
    }

    /// 2026-10-28(수) 지정 시각
    private func wednesday(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: hour, minute: minute))!
    }

    private func day(_ offset: Int, _ hour: Int = 0) -> Date {
        calendar.date(byAdding: .day, value: offset, to: wednesday(hour))!
    }

    /// 지정한 날(수요일 기준 오프셋)들의 회차를 뺍니다.
    private func plan(rule: String?, anchor: Date?, hour: Int, now: Date, lead: Int = 0, excluding offsets: Set<Int>) -> SkipPlan? {
        let cal = calendar
        let excludedDays = offsets.map { cal.startOfDay(for: day($0)) }
        return NotificationManager.skipPlan(
            recurrenceRule: rule, anchor: anchor,
            hour: hour, minute: 0, leadMinutes: lead, now: now, calendar: cal,
            isExcluded: { candidate in excludedDays.contains(cal.startOfDay(for: candidate)) }
        )
    }

    @Test func dailyRoutineCompletedBeforeTodaysAlarmSkipsOnlyToday() {
        // 20:30에 21:00 루틴 완료 → 수요일(4)만 빼고 매주 반복
        guard case .otherWeekdays(let weekdays) = plan(rule: nil, anchor: nil, hour: 21, now: wednesday(20, 30), excluding: [0]) else {
            Issue.record("expected otherWeekdays"); return
        }
        #expect(weekdays == [1, 2, 3, 5, 6, 7])
    }

    @Test func dailyRoutineCompletedAfterTodaysAlarmKeepsNormalRepeat() {
        #expect(plan(rule: nil, anchor: nil, hour: 9, now: wednesday(10), excluding: [0]) == nil)
    }

    @Test func leadTimeAlreadyPassedKeepsNormalRepeat() {
        // 21:00 루틴, 10분 전 알림(20:50)이 이미 지난 20:55에 완료
        #expect(plan(rule: nil, anchor: nil, hour: 21, now: wednesday(20, 55), lead: 10, excluding: [0]) == nil)
    }

    @Test func dailyRoutineSkippedTomorrowDropsThatWeekday() {
        // 목요일(5) 회차만 '이번만 건너뛰기'
        guard case .otherWeekdays(let weekdays) = plan(rule: nil, anchor: nil, hour: 9, now: wednesday(10), excluding: [1]) else {
            Issue.record("expected otherWeekdays"); return
        }
        #expect(weekdays == [1, 2, 3, 4, 6, 7])
    }

    @Test func dailyRoutineSkippedNextMonthKeepsNormalRepeat() {
        #expect(plan(rule: nil, anchor: nil, hour: 9, now: wednesday(10), excluding: [30]) == nil)
    }

    @Test func weeklyCompletedOnItsDaySchedulesFollowingWeeks() {
        let anchor = day(-14)
        guard case .upcoming(let dates) = plan(rule: "weekly", anchor: anchor, hour: 19, now: wednesday(8), excluding: [0]) else {
            Issue.record("expected upcoming"); return
        }
        #expect(dates.first == day(7, 19))
        #expect(dates.count == NotificationManager.upcomingSlotCount - 1)
    }

    @Test func weeklySkippedInTwoWeeksKeepsOtherWeeks() {
        let anchor = day(-14)
        guard case .upcoming(let dates) = plan(rule: "weekly", anchor: anchor, hour: 19, now: wednesday(8), excluding: [14]) else {
            Issue.record("expected upcoming"); return
        }
        #expect(Array(dates.prefix(3)) == [day(0, 19), day(7, 19), day(21, 19)])
    }

    @Test func weeklyOnAnotherWeekdayKeepsNormalRepeat() {
        // 목요일 매주 반복을 수요일에 완료해도 오늘은 회차가 아니므로 평소 반복
        #expect(plan(rule: "weekly", anchor: day(-6), hour: 19, now: wednesday(8), excluding: [0]) == nil)
    }

    @Test func weeklyNotStartedWaitsForItsStartDate() {
        // 다음 달 시작하는 매주 일정은 이번 주에 울리지 않고 시작일부터 직접 예약
        let start = day(35)
        guard case .upcoming(let dates) = plan(rule: "weekly", anchor: start, hour: 19, now: wednesday(8), excluding: []) else {
            Issue.record("expected upcoming"); return
        }
        #expect(dates.first == day(35, 19))
        #expect(dates.count == NotificationManager.upcomingSlotCount)
    }

    @Test func monthlySkipsToTheFollowingOccurrence() {
        let cal = calendar
        let anchor = day(-27)   // 매월 1일
        let skipped = day(4)    // 11월 1일
        let next = NotificationManager.nextIncludedFireDate(
            after: wednesday(8), anchor: anchor, rule: "monthly",
            hour: 9, minute: 0, leadMinutes: 0, calendar: cal,
            isExcluded: { cal.isDate($0, inSameDayAs: skipped) }
        )
        #expect(next == cal.date(from: DateComponents(year: 2026, month: 12, day: 1, hour: 9)))
    }

    @Test func skipIdentifiersAreSeparateFromFollowUps() {
        let skipIDs = NotificationManager.skipDayIdentifiers(for: "ABC")
        #expect(skipIDs.count == 7)
        #expect(Set(skipIDs).isDisjoint(with: NotificationManager.followUpIdentifiers(for: "ABC")))
    }
}

// MARK: - Alert Tone Tests
/// 잠금 화면 한 줄 알림: 말투별 문장, AI 문장 우선순위, 욕 섞기(매운맛 전용, 기본 꺼짐)
@MainActor
struct AlertToneTests {
    private let ko = AlertCopyStrings(language: .ko)

    @Test func everyToneNamesTheTaskOnOneLine() {
        for tone in AlertTone.allCases {
            for stage in [AlertStage.first, .followUp1, .followUp2, .snooze] {
                let line = ko.line(stage, tone: tone, swearing: false, task: "약 먹기")
                #expect(line.contains("약 먹기"))
                #expect(!line.contains("\n"))
            }
        }
        #expect(ko.line(.first, tone: .gentle, swearing: false, task: "약 먹기") == "약 먹기 시간이에요")
    }

    @Test func swearingOnlyChangesSpicy() {
        let calm = ko.line(.first, tone: .gentle, swearing: true, task: "약 먹기")
        #expect(calm == ko.line(.first, tone: .gentle, swearing: false, task: "약 먹기"))
        let spicy = ko.line(.first, tone: .spicy, swearing: false, task: "약 먹기")
        let swearing = ko.line(.first, tone: .spicy, swearing: true, task: "약 먹기")
        #expect(spicy != swearing)
    }

    @Test func aiLineIsUsedOnlyForTheFirstAlert() {
        let first = NotificationManager.alertLine(.first, tone: .gentle, swearing: false,
                                                  aiLine: "약 먹을 시간이에요", task: "약 먹기", copy: ko)
        #expect(first == "약 먹을 시간이에요")
        let follow = NotificationManager.alertLine(.followUp1, tone: .gentle, swearing: false,
                                                   aiLine: "약 먹을 시간이에요", task: "약 먹기", copy: ko)
        #expect(follow == ko.line(.followUp1, tone: .gentle, swearing: false, task: "약 먹기"))
        // 욕 섞기를 켜면 AI 문장 대신 정해 둔 문장을 씁니다.
        let swearing = NotificationManager.alertLine(.first, tone: .spicy, swearing: true,
                                                     aiLine: "약 먹어. 지금.", task: "약 먹기", copy: ko)
        #expect(swearing == ko.line(.first, tone: .spicy, swearing: true, task: "약 먹기"))
    }

    @Test func toneStorageFallsBackToGentle() {
        for tone in AlertTone.allCases {
            #expect(AlertTone(storageIndex: tone.storageIndex) == tone)
        }
        #expect(AlertTone(storageIndex: 99) == .gentle)
        #expect(AlertTone(storageIndex: -1) == .gentle)
    }

    @Test func storedAILineMustMatchToneNameAndLanguage() throws {
        let defaults = try #require(UserDefaults(suiteName: "AlertToneTests-\(UUID().uuidString)"))
        AccountPreferences.activate(for: UUID(), defaults: defaults)
        let id = UUID()
        TaskAlertLines.save("약 먹을 시간이에요", tone: .gentle, language: .ko,
                            taskID: id, taskName: "약 먹기", defaults: defaults)
        #expect(TaskAlertLines.line(taskID: id, taskName: "약 먹기", tone: .gentle,
                                    language: .ko, defaults: defaults) == "약 먹을 시간이에요")
        #expect(TaskAlertLines.line(taskID: id, taskName: "약 먹기", tone: .spicy,
                                    language: .ko, defaults: defaults) == nil)
        #expect(TaskAlertLines.line(taskID: id, taskName: "영양제 먹기", tone: .gentle,
                                    language: .ko, defaults: defaults) == nil)
        #expect(TaskAlertLines.line(taskID: id, taskName: "약 먹기", tone: .gentle,
                                    language: .en, defaults: defaults) == nil)
    }

    @Test func analyzePayloadCarriesTheTone() {
        let payload = CloudLLMManager.makeAnalyzePayload(
            requestID: UUID(), text: "매일 밤 9시 약", now: Date(), language: "ko", alertTone: .spicy
        )
        #expect(payload["alertTone"] == "spicy")
    }

    @Test func decodesAlertLineAndDropsItWhenRenamed() throws {
        var call = try JSONDecoder().decode(LLMFunctionCall.self, from: Data(#"{"function_name":"add_single_task","parameters":{"task_name":"약 먹기","time":"09:00 PM","date":null,"category":"Routine","recurrence":null,"urgency":"strong","alert_line":"약 먹을 시간이에요"}}"#.utf8))
        guard case .addSingleTask(let params) = call else { Issue.record("wrong case"); return }
        #expect(params.alert_line == "약 먹을 시간이에요")
        #expect(call.isExecutionPayloadValid)
        call.updateFields(taskName: "영양제 먹기", time: "09:00 PM", date: nil, category: "Routine")
        guard case .addSingleTask(let renamed) = call else { Issue.record("wrong case"); return }
        #expect(renamed.alert_line == nil)
    }
}
