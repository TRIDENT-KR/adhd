import Foundation
import SwiftData
import Testing
@testable import ADHD

@MainActor
struct TaskAnalysisTests {
    private func context(_ language: String = "ko", now: String = "2026-10-22T10:00:00+09:00", zone: String = "Asia/Seoul") -> TaskAnalysisContext {
        TaskAnalysisContext(now: ISO8601DateFormatter().date(from: now)!, timeZone: TimeZone(identifier: zone)!,
                            language: language, accountScope: "test-scope", accountGeneration: "generation-a")
    }

    @Test(arguments: [
        ("ko", "내일 오후 3시 치과", "치과"),
        ("ko", "내일 오후 3시 치과 추가해줘.", "치과"),
        ("ko", "내일 오후 3시 팀 미팅", "팀 미팅"),
        ("en", "Add Dentist tomorrow at 3 PM.", "Dentist"),
        ("en", "Team meeting tomorrow at 3:00 PM", "Team meeting"),
        ("ja", "明日午後3時に歯医者を追加して", "歯医者"),
        ("ja", "明日午後3時会議", "会議"),
    ])
    func fullInputAndSourceSpans(_ language: String, _ text: String, _ title: String) throws {
        let proposal = try #require(LocalTaskParser.parse(text, context: context(language)))
        guard case .addSingleTask(let p) = proposal.call else { Issue.record("not add"); return }
        #expect(p.task_name == title)
        #expect(p.date == "2026-10-23")
        #expect(p.time == "03:00 PM")
        #expect(p.category == "Appointment")
        #expect(p.recurrence == nil)
        #expect((text as NSString).substring(with: proposal.titleRange) == title)
        #expect(proposal.temporalRange.length > 0)
    }

    // The 18 semantic sentinels from the canonical investigation must all abstain locally.
    @Test(arguments: [
        ("ko", "내일 오후 3시 치과, 아니 4시로 잡아줘."),
        ("en", "Don't forget to call Mom tomorrow at nine."),
        ("ja", "明日の会議は消さず、明後日の会議だけ削除して。"),
        ("ko", "내일 일정 다 지워, 치과만 빼고."),
        ("en", "Move tomorrow's Dentist to Friday at 3 PM."),
        ("ja", "洗濯はまだ終わっていない。完了を取り消して。"),
        ("ko", "병원 일정은 그대로 두고 시간만 없애줘."),
        ("en", "Add a call tomorrow at 9 AM, then move it to Friday at 10 AM."),
        ("ko", "매주 월수금 운동, 다음 주 수요일만 빼줘."),
        ("ja", "毎月第2火曜日、祝日なら翌営業日に請求書を確認。"),
        ("en", "Buy 2 litres of milk and 12 eggs."),
        ("ja", "『全部削除』という名前のタスクを明日午前9時に追加。"),
        ("ko", "내일 아침 8시 약 먹기."),
        ("en", "Schedule the dentist for February 30 at 10 AM."),
        ("en", "Schedule a call in New York on March 14, 2027 at 2:30 AM."),
        ("en", "Schedule a call in New York on November 1, 2026 at 1:30 AM."),
        ("ko", "내일 뉴욕 오전 9시에 전화."),
        ("ja", "全部消して、いや、消さないで。"),
        ("ko", "내일 오후 3시 치과 말고 병원"),
        ("en", "Dentist tomorrow at 3 PM except Monday"),
        ("ja", "明日午後3時に歯医者を追加しないで"),
        ("ko", "내일 오후 3시 치과\n모두 삭제"),
        ("ko", "내일 오후 13시 치과"),
        ("ko", "내일 오후 3시 60분 치과"),
        ("en", "Dentist tomorrow at 3"),
        ("en", "Dentist 2026-02-30 at 3 PM"),
    ])
    func unsupportedInputNeverProducesPartialMutation(_ language: String, _ text: String) {
        #expect(LocalTaskParser.parse(text, context: context(language)) == nil)
    }

    @Test func calendarBoundaryAndTwelveHourClock() throws {
        let c = context(now: "2026-12-31T23:59:50+09:00")
        let proposal = try #require(LocalTaskParser.parse("내일 오전 12시 치과", context: c))
        guard case .addSingleTask(let midnight) = proposal.call else { Issue.record("not add"); return }
        #expect(midnight.date == "2027-01-01")
        #expect(midnight.time == "12:00 AM")
        let noon = try #require(LocalTaskParser.parse("내일 오후 12시 치과", context: c))
        guard case .addSingleTask(let noonParams) = noon.call else { Issue.record("not add"); return }
        #expect(noonParams.time == "12:00 PM")
        #expect(LocalTaskParser.parse("오늘 오전 9시 치과", context: c) == nil)
    }

    @Test func daylightSavingGapAndOverlapAreNotSilentlyChosen() {
        let c = context("en", now: "2026-10-22T10:00:00-04:00", zone: "America/New_York")
        #expect(LocalTaskParser.parse("Dentist 2027-03-14 at 2:30 AM", context: c) == nil)
        #expect(LocalTaskParser.parse("Dentist 2026-11-01 at 1:30 AM", context: c) == nil)
        #expect(LocalTaskParser.parse("Dentist 2027-03-14 at 3:30 AM", context: c) != nil)
    }

    @Test func localResultDoesNotReachConsentNetworkOrQuota() async throws {
        var remoteCalls = 0
        let result = try await TaskAnalysisRouter.analyze(text: "내일 오전 9시 운동 추가해줘.", context: context(),
            isCurrent: { true }, authorizeCloud: { throw CloudLLMError.consentRequired }, cloud: { _, _ in
                remoteCalls += 1
                throw CloudLLMError.quotaExhausted
            })
        #expect(result.source == .localRules)
        #expect(result.requiresPreview)
        #expect(result.quota == nil)
        #expect(remoteCalls == 0)
    }

    @Test func unsupportedOfflineOrUnconsentedDraftNeverUploads() async {
        let errors: [Error] = [TaskAnalysisError.offline, CloudLLMError.consentRequired, CloudLLMError.quotaExhausted]
        for error in errors {
            var remoteCalls = 0
            do {
                _ = try await TaskAnalysisRouter.analyze(text: "내일 오후 3시 치과 아니 4시", context: context(),
                    isCurrent: { true }, authorizeCloud: { throw error }, cloud: { _, _ in
                        remoteCalls += 1
                        throw CloudLLMError.invalidResponse
                    })
                Issue.record("gate was bypassed")
            } catch {}
            #expect(remoteCalls == 0)
        }
    }

    @Test func fallbackUsesSameClockAndDropsLateAccountResult() async throws {
        let captured = context()
        var current = true
        var calls = 0
        let quota = ServerAIQuotaSnapshot(isPro: false, limit: 3, used: 1, reserved: 0, remaining: 2,
                                          usageDate: "2026-10-22", timeZone: "Asia/Seoul")
        do {
            _ = try await TaskAnalysisRouter.analyze(text: "내일 치과 아니 병원", context: captured,
                isCurrent: { current }, authorizeCloud: {}, cloud: { _, received in
                    #expect(received.requestID == captured.requestID)
                    #expect(received.now == captured.now)
                    #expect(received.timeZone == captured.timeZone)
                    calls += 1
                    await Task.yield()
                    current = false
                    return .init(calls: [.requestClarification(.init(reason: "확인해 주세요"))], source: .cloud, quota: quota)
                })
            Issue.record("late result accepted")
        } catch is CancellationError {} catch { Issue.record("wrong error: \(error)") }
        #expect(calls == 1)
    }

    @Test func cancelledRequestCannotFallThroughToCloud() async {
        let c = context()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await TaskAnalysisRouter.analyze(text: "내일 치과", context: c, isCurrent: { true },
                    authorizeCloud: { Issue.record("authorized after cancellation") }, cloud: { _, _ in
                        Issue.record("uploaded after cancellation")
                        throw CloudLLMError.invalidResponse
                    })
                Issue.record("accepted cancelled request")
            } catch is CancellationError {} catch { Issue.record("wrong error") }
        }
        await task.value
    }

    @Test func rolloutGateKeepsUnqualifiedReleaseInputsOnCloud() async {
        var authorizationCount = 0
        do {
            _ = try await TaskAnalysisRouter.analyze(text: "내일 오전 9시 운동 추가해줘.", context: context(),
                localRulesEnabled: false, isCurrent: { true }, authorizeCloud: {
                    authorizationCount += 1
                    throw CloudLLMError.consentRequired
                }, cloud: { _, _ in
                    Issue.record("uploaded without consent")
                    throw CloudLLMError.invalidResponse
                })
            Issue.record("unqualified local path enabled")
        } catch {}
        #expect(authorizationCount == 1)
    }

    @Test func accountGenerationDetectsAToBToA() throws {
        let name = "Mora.analysis-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let a = UUID(), b = UUID()
        AccountPreferences.activate(for: a, defaults: defaults)
        let first = AccountPreferences.sessionGeneration(defaults: defaults)
        AccountPreferences.activate(for: a, defaults: defaults)
        #expect(first == AccountPreferences.sessionGeneration(defaults: defaults))
        AccountPreferences.activate(for: b, defaults: defaults)
        AccountPreferences.activate(for: a, defaults: defaults)
        #expect(first != AccountPreferences.sessionGeneration(defaults: defaults))
        let second = AccountPreferences.sessionGeneration(defaults: defaults)
        AccountPreferences.deactivate(defaults: defaults)
        AccountPreferences.activate(for: a, defaults: defaults)
        #expect(second != AccountPreferences.sessionGeneration(defaults: defaults))
    }

    @Test func payloadUsesCapturedZoneInsteadOfDeviceZone() {
        let c = context()
        let payload = CloudLLMManager.makeAnalyzePayload(requestID: c.requestID, text: "draft", now: c.now,
                                                         language: c.language, timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(payload["currentTime"] == "2026-10-22 01:00")
    }
}

@MainActor
struct AnalysisExecutionBoundaryTests {
    @Test func selectingOneDuplicateChangesOnlyItsUUID() throws {
        let container = try ModelContainer(for: AppTask.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let manager = TaskManager()
        let context = ModelContext(container)
        manager.modelContext = context
        let first = AppTask(task: "팀 회의", category: "Routine")
        let second = AppTask(task: "외부 회의", category: "Routine")
        context.insert(first); context.insert(second); try context.save()
        let call = LLMFunctionCall.markTaskComplete(.init(target_task_name: "회의"))
        var pending = try #require(manager.preparePendingCalls([PendingLLMCall(call: call)]).first)
        #expect(pending.executionIssue == .ambiguousTarget)
        pending.selectTarget(id: UUID())
        #expect(pending.executionIssue == .ambiguousTarget)
        pending.selectTarget(id: second.id)
        let result = manager.executeDetailed(pendingCalls: [pending], explicitlyConfirmed: true)
        #expect(result.allSucceeded)
        #expect(!first.isCompleted && second.isCompleted)
    }

    @Test(arguments: ["25:00", "09:99 AM", "00:30 PM", "09:00 am", "09:00 AM\n"])
    func rejectsInvalidTimes(_ value: String) {
        let call = LLMFunctionCall.addSingleTask(.init(task_name: "회의", time: value, category: "Routine"))
        #expect(!call.isExecutionPayloadValid)
    }

    @Test func rejectsUnknownKeysEnumsDatesAndOversizedBatches() throws {
        for json in [
            #"{"function_name":"add_single_task","extra":true,"parameters":{"task_name":"회의","category":"Routine"}}"#,
            #"{"function_name":"add_single_task","parameters":{"task_name":"회의","category":"Routine","extra":true}}"#,
            #"{"function_name":"update_task","parameters":{"target_task_name":"회의","new_category":"banana"}}"#,
        ] {
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(LLMFunctionCall.self, from: Data(json.utf8)) }
        }
        for call in [
            LLMFunctionCall.addSingleTask(.init(task_name: "회의", date: "2026-02-30", category: "Appointment")),
            .addSingleTask(.init(task_name: "회의", category: "Routine", recurrence: "daily")),
            .addSingleTask(.init(task_name: "회의", category: "Routine", urgency: "critical")),
            .addSingleTask(.init(task_name: String(repeating: "가", count: 201), category: "Routine")),
            .updateTask(.init(target_task_name: "회의", new_task_name: " ")),
        ] { #expect(!call.isExecutionPayloadValid) }
        let valid = LLMFunctionCall.addSingleTask(.init(task_name: "회의", category: "Routine"))
        #expect(!LLMFunctionCall.isValidAnalysis(Array(repeating: valid, count: 51)))
        #expect(!LLMFunctionCall.isValidAnalysis([valid, .handleOffTopicChat(.init(message: "hello"))]))
    }

    @Test func clearingTimeIsAllowedOnlyAfterLocalEditing() {
        let edited = LLMFunctionCall.updateTask(.init(target_task_name: "회의", new_time: ""))
        #expect(edited.isExecutionPayloadValid)
        #expect(!LLMFunctionCall.isValidAnalysis([edited]))
        let cloud = LLMFunctionCall.updateTask(.init(target_task_name: "회의", new_time: "09:00 AM"))
        #expect(LLMFunctionCall.isValidAnalysis([cloud]))
    }

    @Test func duplicateTargetsRequireSelectionAndSelectedSnapshotCanBecomeStale() throws {
        let container = try ModelContainer(for: AppTask.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let manager = TaskManager()
        let context = ModelContext(container)
        manager.modelContext = context
        let first = AppTask(task: "회의", category: "Routine")
        let second = AppTask(task: "회의", category: "Routine")
        context.insert(first); context.insert(second); try context.save()
        let call = LLMFunctionCall.markTaskComplete(.init(target_task_name: "회의"))
        var pending = try #require(manager.preparePendingCalls([PendingLLMCall(call: call)]).first)
        #expect(pending.executionIssue == .ambiguousTarget)
        #expect(pending.targetCandidates.count == 2)
        #expect(!manager.executeDetailed(pendingCalls: [pending], explicitlyConfirmed: true).hasAnySuccess)
        #expect(!first.isCompleted && !second.isCompleted)
        pending.selectTarget(id: second.id)
        second.task = "회의 변경됨"; try context.save()
        let result = manager.executeDetailed(pendingCalls: [pending], explicitlyConfirmed: true)
        #expect(result.items.first?.issue == .staleTarget)
        #expect(!first.isCompleted && !second.isCompleted)
    }

    @Test func staleDuplicateSelectionKeepsCandidatesForRetry() throws {
        let container = try ModelContainer(for: AppTask.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let manager = TaskManager()
        let context = ModelContext(container)
        manager.modelContext = context
        let first = AppTask(task: "회의", category: "Routine")
        let second = AppTask(task: "회의", category: "Routine")
        context.insert(first); context.insert(second); try context.save()
        let call = LLMFunctionCall.markTaskComplete(.init(target_task_name: "회의"))
        var pending = try #require(manager.preparePendingCalls([PendingLLMCall(call: call)]).first)
        pending.selectTarget(id: second.id)
        second.time = "10:00 AM"; try context.save()
        let stale = manager.executeDetailed(pendingCalls: [pending], explicitlyConfirmed: true)
        #expect(stale.items.first?.issue == .staleTarget)
        var retry = try #require(stale.remainingCalls.first)
        #expect(retry.executionIssue == .ambiguousTarget)
        #expect(retry.targetCandidates.count == 2)
        #expect(!first.isCompleted && !second.isCompleted)
        retry.selectTarget(id: second.id)
        let result = manager.executeDetailed(pendingCalls: [retry], explicitlyConfirmed: true)
        #expect(result.allSucceeded)
        #expect(!first.isCompleted && second.isCompleted)
    }

}
