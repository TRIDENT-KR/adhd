import Testing
import Foundation
import AVFoundation
@testable import ADHD

// MARK: - LLMFunctionCall 디코딩 Tests
/// Gemini 응답 JSON → 함수 8종 라우팅 + 카테고리 정규화 + 편집 규약 검증
@MainActor
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

    // MARK: 파괴적 명령 확인 정책

    @Test func destructiveCommandsAlwaysRequireConfirmation() throws {
        let delete = try decode(#"{"function_name":"delete_specific_task","parameters":{"target_task_name":"운동"}}"#)
        let clear = try decode(#"{"function_name":"clear_all_tasks","parameters":{"target_date":"all"}}"#)
        let postpone = try decode(#"{"function_name":"postpone_all_tasks","parameters":{"from_date":"2026-07-09","to_date":"2026-07-10"}}"#)

        #expect(delete.requiresExplicitConfirmation)
        #expect(clear.requiresExplicitConfirmation)
        #expect(postpone.requiresExplicitConfirmation)
    }

    @Test func destructiveAllCategoryIsPreserved() throws {
        let call = try decode(#"{"function_name":"delete_specific_task","parameters":{"target_task_name":"운동","target_category":"all","target_date":"all"}}"#)
        guard case .deleteSpecificTask(let params) = call else {
            Issue.record("wrong case")
            return
        }

        #expect(params.target_category == "all")
        #expect(call.isExecutionPayloadValid)
    }

    @Test func malformedDestructiveDatesAreInvalid() {
        let delete = LLMFunctionCall.deleteSpecificTask(
            DeleteTaskParams(target_task_name: "운동", target_category: nil, target_date: "2026-02-30")
        )
        let postpone = LLMFunctionCall.postponeAllTasks(
            PostponeTasksParams(from_date: "tomorrow", to_date: "2026-08-05")
        )

        #expect(!delete.isExecutionPayloadValid)
        #expect(!postpone.isExecutionPayloadValid)
    }

    @Test func safeSingleCommandsCanFollowUserConfirmationSetting() throws {
        let add = try decode(#"{"function_name":"add_single_task","parameters":{"task_name":"약 먹기","category":"Routine"}}"#)
        let update = try decode(#"{"function_name":"update_task","parameters":{"target_task_name":"회의","new_time":"03:00 PM"}}"#)
        let complete = try decode(#"{"function_name":"mark_task_complete","parameters":{"target_task_name":"물 마시기"}}"#)

        #expect(!LLMConfirmationPolicy.requiresExplicitConfirmation(for: [add]))
        #expect(!LLMConfirmationPolicy.requiresExplicitConfirmation(for: [update]))
        #expect(!LLMConfirmationPolicy.requiresExplicitConfirmation(for: [complete]))
    }

    @Test func multipleExistingTaskMutationsRequireConfirmation() throws {
        let update = try decode(#"{"function_name":"update_task","parameters":{"target_task_name":"회의","new_time":"03:00 PM"}}"#)
        let complete = try decode(#"{"function_name":"mark_task_complete","parameters":{"target_task_name":"물 마시기"}}"#)

        #expect(LLMConfirmationPolicy.requiresExplicitConfirmation(for: [update, complete]))
    }

    @Test func mixedBatchUsesStrictestConfirmationRule() throws {
        let add = try decode(#"{"function_name":"add_single_task","parameters":{"task_name":"약 먹기","category":"Routine"}}"#)
        let delete = try decode(#"{"function_name":"delete_specific_task","parameters":{"target_task_name":"운동"}}"#)

        #expect(LLMConfirmationPolicy.requiresExplicitConfirmation(for: [add, delete]))
    }
}

@MainActor
struct ServerAIQuotaSnapshotTests {
    @Test func acceptsStrictKSTFreeQuotaSnapshot() {
        let snapshot = ServerAIQuotaSnapshot(
            isPro: false,
            limit: 3,
            used: 1,
            reserved: 0,
            remaining: 2,
            usageDate: "2026-08-04",
            timeZone: "Asia/Seoul"
        )

        #expect(snapshot.isValid)
    }

    @Test func rejectsClientAmbiguousOrInconsistentQuota() {
        let wrongZone = ServerAIQuotaSnapshot(
            isPro: false,
            limit: 3,
            used: 1,
            reserved: 0,
            remaining: 2,
            usageDate: "2026-08-04",
            timeZone: "UTC"
        )
        let wrongTotal = ServerAIQuotaSnapshot(
            isPro: false,
            limit: 3,
            used: 1,
            reserved: 1,
            remaining: 2,
            usageDate: "2026-08-04",
            timeZone: "Asia/Seoul"
        )

        #expect(!wrongZone.isValid)
        #expect(!wrongTotal.isValid)
    }

    @Test func proQuotaHasNoSyntheticLimit() {
        let snapshot = ServerAIQuotaSnapshot(
            isPro: true,
            limit: nil,
            used: 2,
            reserved: 0,
            remaining: nil,
            usageDate: "2026-08-04",
            timeZone: "Asia/Seoul"
        )

        #expect(snapshot.isValid)
    }
}

// MARK: - 서버 오류 → 화면 동작 매핑
/// 429라도 quota_exhausted만 결제 화면으로 보내고, 재시도 횟수는 서버 예산(3회)과 맞춥니다.
@MainActor
struct CloudLLMErrorMappingTests {

    @Test func onlyQuotaExhaustedOpensPaywall() {
        #expect(CloudLLMManager.mappedHTTPError(status: 429, code: "quota_exhausted") == .quotaExhausted)
    }

    @Test func otherTooManyRequestsAreRetryLater() {
        #expect(CloudLLMManager.mappedHTTPError(status: 429, code: "rate_limited") == .rateLimited)
        #expect(CloudLLMManager.mappedHTTPError(status: 429, code: "request_replay_limit") == .rateLimited)
        #expect(CloudLLMManager.mappedHTTPError(status: 429, code: nil) == .rateLimited)
    }

    @Test func nonQuotaStatusesKeepTheirMapping() {
        #expect(CloudLLMManager.mappedHTTPError(status: 403, code: "adult_eligibility_required") == .adultEligibilityRequired)
        #expect(CloudLLMManager.mappedHTTPError(status: 401, code: "unauthorized") == .authenticationRequired)
        #expect(CloudLLMManager.mappedHTTPError(status: 409, code: "request_conflict") == .requestRejected)
        #expect(CloudLLMManager.mappedHTTPError(status: 502, code: "gemini_request_failed") == .serverUnavailable)
    }

    @Test func serverRetryableFailuresAreRetried() {
        #expect(CloudLLMManager.isRetryableHTTPFailure(status: 502, code: "gemini_request_failed"))
        #expect(CloudLLMManager.isRetryableHTTPFailure(status: 502, code: "gemini_network_failed"))
        #expect(CloudLLMManager.isRetryableHTTPFailure(status: 502, code: "analysis_failed"))
        #expect(CloudLLMManager.isRetryableHTTPFailure(status: 503, code: "quota_backend_failed"))
        #expect(CloudLLMManager.isRetryableHTTPFailure(status: 409, code: "analysis_in_progress"))
    }

    @Test func limitsAndInvalidOutputAreNotRetried() {
        #expect(!CloudLLMManager.isRetryableHTTPFailure(status: 429, code: "rate_limited"))
        #expect(!CloudLLMManager.isRetryableHTTPFailure(status: 429, code: "request_replay_limit"))
        #expect(!CloudLLMManager.isRetryableHTTPFailure(status: 429, code: "quota_exhausted"))
        #expect(!CloudLLMManager.isRetryableHTTPFailure(status: 502, code: "invalid_model_response"))
    }

    @Test func clientAttemptsMatchServerReplayBudget() {
        #expect(CloudLLMManager.maxAttempts == 3)
    }
}

// MARK: - 확인 카드 표시
/// 저장 형식("2026-10-29", "03:00 PM")을 그대로 보여주지 않고 앱 언어로 바꿉니다.
@MainActor
struct ConfirmCardDisplayTests {

    private var now: Date {
        Calendar.current.date(
            byAdding: .hour,
            value: 12,
            to: StoredTaskFormat.date.date(from: "2026-10-28")!
        )!
    }

    @Test func todayAndTomorrowAreWords() {
        #expect(ConfirmCardDateFormat.displayDate("2026-10-28", now: now, language: .ko) == "오늘")
        #expect(ConfirmCardDateFormat.displayDate("2026-10-29", now: now, language: .ko) == "내일")
        #expect(ConfirmCardDateFormat.displayDate("2026-10-28", now: now, language: .en) == "Today")
        #expect(ConfirmCardDateFormat.displayDate("2026-10-29", now: now, language: .ja) == "明日")
    }

    @Test func otherDatesUseMonthAndDayInAppLanguage() {
        #expect(ConfirmCardDateFormat.displayDate("2026-11-05", now: now, language: .ko) == "11월 5일")
        #expect(ConfirmCardDateFormat.displayDate("2026-11-05", now: now, language: .en) == "Nov 5")
        #expect(ConfirmCardDateFormat.displayDate("2026-11-05", now: now, language: .ja) == "11月5日")
    }

    @Test func otherYearIncludesYear() {
        let text = ConfirmCardDateFormat.displayDate("2027-01-05", now: now, language: .ko)
        #expect(text.contains("2027"))
        #expect(!text.contains("-"))
    }

    @Test func unreadableDateFallsBackToRawValue() {
        #expect(ConfirmCardDateFormat.displayDate("someday", now: now, language: .ko) == "someday")
    }

    @Test func koreanTodayIsNotTodaysTasks() {
        #expect(Strings(language: .ko).voice.confirmToday == "오늘")
    }

    @Test func smartDateTimeUsesDisplayFormats() {
        let today = StoredTaskFormat.date.string(from: Date())
        let call = LLMFunctionCall.addSingleTask(AddSingleTaskParams(
            task_name: "치과",
            time: "03:00 PM",
            date: today,
            category: "Appointment",
            recurrence: nil,
            urgency: nil
        ))

        #expect(call.uiSmartDateTime == "\(ConfirmCardDateFormat.displayDate(today)) \(StoredTaskFormat.displayTime("03:00 PM"))")
        #expect(!call.uiSmartDateTime.contains(today))
    }

    @Test func clearAllDateIsNotShownAsRawAll() {
        let call = LLMFunctionCall.deleteSpecificTask(
            DeleteTaskParams(target_task_name: "운동", target_category: "all", target_date: "all")
        )
        #expect(call.uiSmartDateTime.isEmpty)
    }
}

// MARK: - 되묻기·잡담 응답
/// 저장이 아닌 응답은 성공으로 세지 않고, 루틴처럼 보이지도 않아야 합니다.
@MainActor
struct FeedbackOnlyCallTests {

    @Test func clarificationAndOffTopicAreFeedbackOnly() {
        let clarify = LLMFunctionCall.requestClarification(ClarificationParams(reason: "몇 시에 할까요?"))
        let offTopic = LLMFunctionCall.handleOffTopicChat(OffTopicChatParams(message: "일정 이야기를 해 주세요"))
        let add = LLMFunctionCall.addSingleTask(AddSingleTaskParams(
            task_name: "약 먹기", time: nil, date: nil, category: "Routine", recurrence: nil, urgency: nil
        ))

        #expect(clarify.isFeedbackOnly)
        #expect(offTopic.isFeedbackOnly)
        #expect(!add.isFeedbackOnly)
        #expect(clarify.feedbackMessage == "몇 시에 할까요?")
        #expect(offTopic.feedbackMessage == "일정 이야기를 해 주세요")
    }

    @Test func clarificationIsNotShownAsRoutine() {
        let pending = PendingLLMCall(call: .requestClarification(ClarificationParams(reason: "어느 회의인가요?")))

        #expect(pending.uiCategory != "Routine")
        #expect(pending.uiCategory != "Appointment")
        #expect(pending.uiActionLabel == L.voice.confirmClarify)
    }
}

// MARK: - 확인 카드 편집
/// 명령 종류마다 고칠 수 있는 범위가 다르고, 수정 카드는 바꾼 항목만 반영합니다.
@MainActor
struct PendingCallEditTests {

    private func routineTarget(_ name: String = "운동", time: String? = "07:00 AM") -> AppTaskSnapshot {
        AppTaskSnapshot(AppTask(task: name, time: time, category: "Routine"))
    }

    private func updatePending(target: AppTaskSnapshot, newTime: String? = nil) -> PendingLLMCall {
        var pending = PendingLLMCall(call: .updateTask(UpdateTaskParams(
            target_task_name: target.task,
            new_task_name: nil,
            new_time: newTime,
            new_date: nil,
            new_category: nil,
            new_recurrence: nil
        )))
        pending.targetSnapshots = [target]
        return pending
    }

    @Test func updateDraftShowsTargetValues() throws {
        let pending = updatePending(target: routineTarget(), newTime: "08:00 AM")
        let draft = try #require(pending.makeEditDraft())

        #expect(draft.scope == .allFields)
        #expect(draft.name == "운동")
        #expect(draft.category == "Routine")      // 기존처럼 플래너로 바뀌지 않음
        #expect(draft.date == nil)
        #expect(draft.time == "08:00 AM")
        #expect(pending.uiCategory == "Routine")
    }

    @Test func renamingRoutineOnlyChangesName() throws {
        var pending = updatePending(target: routineTarget())
        let baseline = try #require(pending.makeEditDraft())
        var edited = baseline
        edited.name = "아침 운동"

        let didChange = pending.applyEdit(edited, from: baseline)
        #expect(didChange)
        guard case .updateTask(let params) = pending.call else { Issue.record("wrong case"); return }
        #expect(params.new_task_name == "아침 운동")
        #expect(params.new_category == nil)         // 하루짜리 플래너로 바뀌지 않음
        #expect(params.new_date == nil)
        #expect(params.new_time == nil)
    }

    @Test func changingOnlyTimeKeepsOtherFields() throws {
        var pending = updatePending(target: routineTarget())
        let baseline = try #require(pending.makeEditDraft())
        var edited = baseline
        edited.time = "09:30 AM"

        let didChange = pending.applyEdit(edited, from: baseline)
        #expect(didChange)
        guard case .updateTask(let params) = pending.call else { Issue.record("wrong case"); return }
        #expect(params.new_time == "09:30 AM")
        #expect(params.new_task_name == nil)
        #expect(params.new_category == nil)
        #expect(params.new_date == nil)
    }

    @Test func clearingTimeOnUpdateUsesClearMarker() throws {
        var pending = updatePending(target: routineTarget())
        let baseline = try #require(pending.makeEditDraft())
        var edited = baseline
        edited.time = nil

        let didChange = pending.applyEdit(edited, from: baseline)
        #expect(didChange)
        guard case .updateTask(let params) = pending.call else { Issue.record("wrong case"); return }
        #expect(params.new_time == "")
    }

    @Test func unchangedSaveDoesNotTouchUpdate() throws {
        var pending = updatePending(target: routineTarget(), newTime: "08:00 AM")
        let baseline = try #require(pending.makeEditDraft())
        var sameClock = baseline
        sameClock.time = "8:00 AM"                  // 표기만 다른 같은 시각

        let didChange = pending.applyEdit(sameClock, from: baseline)
        #expect(!didChange)
        guard case .updateTask(let params) = pending.call else { Issue.record("wrong case"); return }
        #expect(params.new_time == "08:00 AM")
    }

    @Test func deleteCardOnlyRetargetsName() throws {
        var pending = PendingLLMCall(call: .deleteSpecificTask(
            DeleteTaskParams(target_task_name: "운동", target_category: nil, target_date: nil)
        ))
        let baseline = try #require(pending.makeEditDraft())
        #expect(baseline.scope == .targetName)

        var edited = baseline
        edited.name = "저녁 운동"
        edited.category = "Appointment"
        edited.date = StoredTaskFormat.date.string(from: Date())

        let didChange = pending.applyEdit(edited, from: baseline)
        #expect(didChange)
        guard case .deleteSpecificTask(let params) = pending.call else { Issue.record("wrong case"); return }
        #expect(params.target_task_name == "저녁 운동")
        #expect(params.target_category == nil)      // 오늘 날짜 필터가 끼어들지 않음
        #expect(params.target_date == nil)
    }

    @Test func completeCardOnlyRetargetsName() throws {
        var pending = PendingLLMCall(call: .markTaskComplete(MarkTaskCompleteParams(target_task_name: "물")))
        let baseline = try #require(pending.makeEditDraft())
        var edited = baseline
        edited.name = "물 마시기"

        let didChange = pending.applyEdit(edited, from: baseline)
        #expect(didChange)
        guard case .markTaskComplete(let params) = pending.call else { Issue.record("wrong case"); return }
        #expect(params.target_task_name == "물 마시기")
    }

    @Test func addCardCanKeepNoTime() throws {
        var pending = PendingLLMCall(call: .addSingleTask(AddSingleTaskParams(
            task_name: "빨래", time: nil, date: nil, category: "Routine", recurrence: nil, urgency: nil
        )))
        let baseline = try #require(pending.makeEditDraft())
        #expect(baseline.time == nil)

        var edited = baseline
        edited.name = "빨래 개기"
        let didChange = pending.applyEdit(edited, from: baseline)
        #expect(didChange)
        guard case .addSingleTask(let params) = pending.call else { Issue.record("wrong case"); return }
        #expect(params.task_name == "빨래 개기")
        #expect(params.time == nil)                 // 자정으로 채우지 않음
    }

    @Test func undatedAppointmentDefaultsToTodayAndSavesIt() throws {
        let today = StoredTaskFormat.date.string(from: Date())
        var pending = PendingLLMCall(call: .addSingleTask(AddSingleTaskParams(
            task_name: "병원", time: nil, date: nil, category: "Appointment", recurrence: nil, urgency: nil
        )))
        let baseline = try #require(pending.makeEditDraft())
        #expect(baseline.date == today)

        // 폼을 건드리지 않고 저장해도 보이던 오늘 날짜가 저장되어야 다시 막히지 않습니다.
        let didChange = pending.applyEdit(baseline, from: baseline)
        #expect(didChange)
        guard case .addSingleTask(let params) = pending.call else { Issue.record("wrong case"); return }
        #expect(params.date == today)
        #expect(params.time == nil)
    }
}

// MARK: - P2 홈·음성 (서버 검증 기준, 대기 상한, 원인별 안내, 배지, 녹음 형식)
@MainActor
struct HomeVoiceReliabilityTests {

    @Test func oneCharacterDeleteTargetMatchesServerRule() {
        // 서버는 빈 이름만 거부하므로 '약 지워줘'도 유효합니다(대상 찾기에서 정확히 같은 이름만 고름).
        let delete = LLMFunctionCall.deleteSpecificTask(
            DeleteTaskParams(target_task_name: "약", target_category: "all", target_date: "all")
        )
        let blank = LLMFunctionCall.deleteSpecificTask(
            DeleteTaskParams(target_task_name: "  ", target_category: "all", target_date: "all")
        )
        #expect(delete.isExecutionPayloadValid)
        #expect(!blank.isExecutionPayloadValid)
    }

    @Test func analysisNeverWaitsLongerThanTheOverallDeadline() {
        #expect(CloudLLMManager.attemptTimeout(elapsed: 0) == 15)
        #expect(CloudLLMManager.attemptTimeout(elapsed: 20) == 10)
        #expect(CloudLLMManager.attemptTimeout(elapsed: 28) == nil)
        #expect(CloudLLMManager.totalDeadline == 30)
    }

    @Test func tooLongAndOfflineGetTheirOwnErrors() {
        #expect(CloudLLMManager.mappedHTTPError(status: 400, code: "input_too_long") == .inputTooLong)
        #expect(CloudLLMManager.mappedHTTPError(status: 400, code: "invalid_request") == .requestRejected)
        #expect(CloudLLMManager.isOfflineError(.notConnectedToInternet))
        #expect(!CloudLLMManager.isOfflineError(.timedOut))
    }

    @Test func draftLengthAppearsOnlyNearTheLimit() {
        #expect(!HomeVoiceInterfaceView.showsDraftLength(String(repeating: "가", count: 800)))
        #expect(HomeVoiceInterfaceView.showsDraftLength(String(repeating: "가", count: 801)))
    }

    @Test func badgeRefillsAfterServerMidnight() {
        var seoul = Calendar(identifier: .gregorian)
        seoul.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let sameDay = seoul.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 23))!
        let nextDay = seoul.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 0, minute: 5))!

        #expect(ServerQuotaAccessPolicy.displayedRemaining(
            remaining: 0, usageDate: "2026-10-29", timeZone: "Asia/Seoul", limit: 3, now: sameDay) == 0)
        #expect(ServerQuotaAccessPolicy.displayedRemaining(
            remaining: 0, usageDate: "2026-10-29", timeZone: "Asia/Seoul", limit: 3, now: nextDay) == 3)
        #expect(ServerQuotaAccessPolicy.displayedRemaining(
            remaining: nil, usageDate: nil, timeZone: nil, limit: 3, now: sameDay) == 3)
    }

    @Test func zeroAudioFormatIsRejectedBeforeInstallingTap() {
        #expect(!VoiceInputManager.isUsableRecordingFormat(sampleRate: 0, channelCount: 1))
        #expect(!VoiceInputManager.isUsableRecordingFormat(sampleRate: 48_000, channelCount: 0))
        #expect(VoiceInputManager.isUsableRecordingFormat(sampleRate: 48_000, channelCount: 1))
    }

    @Test func onlyDeviceChangesStopRecording() {
        #expect(VoiceInputManager.isInputDeviceChange(.newDeviceAvailable))
        #expect(VoiceInputManager.isInputDeviceChange(.oldDeviceUnavailable))
        // 녹음을 시작하며 카테고리를 바꿀 때 오는 알림에는 멈추지 않습니다.
        #expect(!VoiceInputManager.isInputDeviceChange(.categoryChange))
        #expect(!VoiceInputManager.isInputDeviceChange(nil))
    }

    @Test func onlyRecognitionFailuresOfferRecording() {
        #expect(VoiceError.emptyTranscription.canRetryRecording)
        #expect(!VoiceError.speechPermissionDenied.canRetryRecording)
        #expect(!VoiceError.speechRestricted.canRetryRecording)
    }
}
