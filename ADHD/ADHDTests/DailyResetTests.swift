import Testing
import Foundation
import SwiftData
@testable import ADHD

// MARK: - TaskManager.checkAndResetDailyTasks Tests
/// in-memory ModelContainer + 주입된 UserDefaults/now로 날짜 경계 로직을 검증한다.
@MainActor
struct DailyResetTests {

    private let cal = Calendar.current

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func makeManager() throws -> TaskManager {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: AppTask.self, configurations: config)
        let manager = TaskManager()
        manager.modelContext = ModelContext(container)
        return manager
    }

    private func freshDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func sameDayIsNoOp() throws {
        let manager = try makeManager()
        let defaults = freshDefaults("test.dailyreset.sameday")
        let now = date(2026, 7, 8)
        defaults.set(now, forKey: "lastResetDate")

        let routine = AppTask(task: "루틴", category: "Routine", isCompleted: true)
        manager.modelContext!.insert(routine)

        manager.checkAndResetDailyTasks(now: now, defaults: defaults)
        #expect(routine.isCompleted == true)   // 같은 날 재호출 → 리셋 없음
    }

    @Test func nextDayResetsCompletionAndRecordsYesterday() throws {
        let manager = try makeManager()
        let defaults = freshDefaults("test.dailyreset.nextday")
        // 화(7/7) → 수(7/8): 같은 ISO 주 내 하루 경과
        defaults.set(date(2026, 7, 7), forKey: "lastResetDate")

        let routine = AppTask(task: "루틴", category: "Routine", isCompleted: true)
        manager.modelContext!.insert(routine)

        manager.checkAndResetDailyTasks(now: date(2026, 7, 8), defaults: defaults)

        #expect(routine.isCompleted == false)                            // 새 날 → 완료 리셋
        #expect(routine.weeklyCompletions.filter { $0 }.count == 1)      // 어제 요일에 완료 기록
    }

    @Test func weekBoundaryClearsWeeklyCompletions() throws {
        let manager = try makeManager()
        let defaults = freshDefaults("test.dailyreset.weekboundary")
        // 일(7/5) → 월(7/6): ISO 주 경계(월요일 시작)를 넘음
        defaults.set(date(2026, 7, 5), forKey: "lastResetDate")

        let routine = AppTask(task: "루틴", category: "Routine", isCompleted: true)
        routine.weeklyCompletions = Array(repeating: true, count: 7)
        manager.modelContext!.insert(routine)

        manager.checkAndResetDailyTasks(now: date(2026, 7, 6), defaults: defaults)

        #expect(routine.isCompleted == false)
        #expect(routine.weeklyCompletions.allSatisfy { !$0 })            // 주 경계 → 전체 초기화
    }

    @Test func secondCallOnSameDayDoesNotDoubleReset() throws {
        let manager = try makeManager()
        let defaults = freshDefaults("test.dailyreset.idempotent")
        defaults.set(date(2026, 7, 7), forKey: "lastResetDate")

        let routine = AppTask(task: "루틴", category: "Routine", isCompleted: true)
        manager.modelContext!.insert(routine)

        let now = date(2026, 7, 8)
        manager.checkAndResetDailyTasks(now: now, defaults: defaults)
        routine.isCompleted = true   // 사용자가 오늘 다시 완료
        manager.checkAndResetDailyTasks(now: now, defaults: defaults)

        #expect(routine.isCompleted == true)   // 같은 날 2번째 호출은 no-op
    }

    @Test func accountResetDateIsIndependentFromOtherStores() throws {
        let manager = try makeManager()
        let defaults = freshDefaults("test.dailyreset.scoped")
        let today = date(2026, 7, 8)
        defaults.set("scopeA", forKey: "mora.active-account-preference-scope.v1")
        defaults.set(date(2026, 7, 7), forKey: "mora.account.scopeA.lastResetDate.v1")
        defaults.set(today, forKey: "lastResetDate")   // 게스트 저장소가 오늘 먼저 초기화함

        let routine = AppTask(task: "루틴", category: "Routine", isCompleted: true)
        manager.modelContext!.insert(routine)

        manager.checkAndResetDailyTasks(now: today, defaults: defaults)
        #expect(routine.isCompleted == false)   // 계정 A 기준일은 어제라 초기화되어야 함
        #expect(defaults.object(forKey: "mora.account.scopeA.lastResetDate.v1") as? Date == today)
    }

    @Test func clearingCompletedKeepsRoutinesAndRepeatingSeries() throws {
        let manager = try makeManager()
        let context = manager.modelContext!
        let past = date(2026, 7, 1)
        let doneOnce = AppTask(task: "치과", date: past, category: "Appointment", isCompleted: true)
        let doneWeekly = AppTask(task: "상담", date: past, category: "Appointment", isCompleted: true, recurrenceRule: "weekly")
        let doneRoutine = AppTask(task: "약", category: "Routine", isCompleted: true)
        let openOnce = AppTask(task: "회의", date: past, category: "Appointment")
        for task in [doneOnce, doneWeekly, doneRoutine, openOnce] { context.insert(task) }

        #expect(manager.completedClearableCount() == 1)
        manager.deleteCompleted()

        let remaining = Set(try context.fetch(FetchDescriptor<AppTask>()).map(\.task))
        #expect(remaining == ["상담", "약", "회의"])
        manager.undo()
        #expect(try context.fetch(FetchDescriptor<AppTask>()).count == 4)
    }

    @Test func staleWidgetPayloadShowsTodayState() {
        let yesterday = date(2026, 7, 7)
        let today = date(2026, 7, 8)
        let routine = WidgetTaskSnapshot(id: UUID(), task: "약", time: "09:00 PM", category: "Routine", isCompleted: true, recurrenceLabel: nil)
        let appointment = WidgetTaskSnapshot(id: UUID(), task: "치과", time: "03:00 PM", category: "Appointment", isCompleted: false, recurrenceLabel: nil)
        let payload = WidgetDataPayload(accountScope: "s", routines: [routine], appointments: [appointment], updatedAt: yesterday)

        let normalized = payload.normalized(for: today)
        #expect(normalized.routines.first?.isCompleted == false)
        #expect(normalized.appointments.isEmpty)
        #expect(payload.normalized(for: yesterday).routines.first?.isCompleted == true)
    }

    @Test func widgetRefreshesAtMidnightAtTheLatest() {
        let lateNight = cal.date(from: DateComponents(year: 2026, month: 7, day: 7, hour: 23, minute: 55))!
        #expect(WidgetDataPayload.nextRefreshDate(after: lateNight, calendar: cal) == date(2026, 7, 8))
        let noon = cal.date(from: DateComponents(year: 2026, month: 7, day: 7, hour: 12))!
        #expect(WidgetDataPayload.nextRefreshDate(after: noon, calendar: cal) == noon.addingTimeInterval(900))
    }

    @Test func widgetShowsPreparedListTheDayAfter() {
        let yesterdayNoon = cal.date(from: DateComponents(year: 2026, month: 7, day: 7, hour: 12))!
        let justAfterMidnight = cal.date(from: DateComponents(year: 2026, month: 7, day: 8, minute: 5))!
        let yesterdayOnly = WidgetTaskSnapshot(id: UUID(), task: "어제만", time: nil, category: "Routine", isCompleted: true, recurrenceLabel: nil)
        let routine = WidgetTaskSnapshot(id: UUID(), task: "약", time: "09:00 PM", category: "Routine", isCompleted: false, recurrenceLabel: nil)
        let dentist = WidgetTaskSnapshot(id: UUID(), task: "치과", time: "03:00 PM", category: "Appointment", isCompleted: false, recurrenceLabel: nil)
        let payload = WidgetDataPayload(
            accountScope: "s", routines: [yesterdayOnly], appointments: [], updatedAt: yesterdayNoon,
            nextDay: WidgetDayTasks(routines: [routine], appointments: [dentist])
        )

        let today = payload.normalized(for: justAfterMidnight, calendar: cal)
        #expect(today.routines.map(\.task) == ["약"])
        #expect(today.appointments.map(\.task) == ["치과"])
        // 위젯에서 체크한 뒤 다시 읽어도 그날 일정이 사라지지 않습니다.
        let evening = cal.date(from: DateComponents(year: 2026, month: 7, day: 8, hour: 18))!
        #expect(today.normalized(for: evening, calendar: cal).appointments.map(\.task) == ["치과"])
        // 이틀 넘게 지나면 미리 담은 목록도 맞지 않으므로 예전처럼 일정은 숨깁니다.
        #expect(payload.normalized(for: date(2026, 7, 9), calendar: cal).appointments.isEmpty)
    }

    @Test func payloadFromPreviousAppVersionStillDecodes() throws {
        let json = #"{"accountScope":"s","routines":[],"appointments":[],"updatedAt":0}"#
        let payload = try JSONDecoder().decode(WidgetDataPayload.self, from: Data(json.utf8))
        #expect(payload.nextDay == nil)
        #expect(payload.hasTasks == false)
    }

    @Test func nextDayWidgetListResetsOnlyTasksThatResetDaily() {
        let today = date(2026, 7, 7)
        let tomorrow = date(2026, 7, 8)   // 수요일
        let daily = AppTask(task: "약", time: "09:00 PM", category: "Routine", isCompleted: true)
        let todayOnlyRoutine = AppTask(task: "오늘만 루틴", date: today, category: "Routine")
        let weekly = AppTask(task: "회의", time: "02:00 PM", date: date(2026, 7, 1), category: "Appointment",
                             isCompleted: true, recurrenceRule: "weekly")
        let dentist = AppTask(task: "치과", time: "03:00 PM", date: tomorrow, category: "Appointment", isCompleted: true)
        let lunch = AppTask(task: "점심 약속", date: today, category: "Appointment")

        let list = TaskManager.widgetDayTasks(from: [daily, todayOnlyRoutine, weekly, dentist, lunch], on: tomorrow)
        #expect(list.routines.map(\.task) == ["약"])
        #expect(list.routines.map(\.isCompleted) == [false])
        #expect(list.appointments.map(\.task) == ["회의", "치과"])
        #expect(list.appointments.map(\.isCompleted) == [false, true])   // 반복 일정만 새로 시작
    }

    @Test func accountWithoutOwnResetDateInheritsLegacyValueOnce() throws {
        let manager = try makeManager()
        let defaults = freshDefaults("test.dailyreset.legacy")
        let today = date(2026, 7, 8)
        defaults.set("scopeB", forKey: "mora.active-account-preference-scope.v1")
        defaults.set(today, forKey: "lastResetDate")   // 업데이트 전 전역 값

        let routine = AppTask(task: "루틴", category: "Routine", isCompleted: true)
        manager.modelContext!.insert(routine)

        manager.checkAndResetDailyTasks(now: today, defaults: defaults)
        #expect(routine.isCompleted == true)   // 오늘 이미 초기화된 것으로 이어받음
    }
}

// MARK: - 주간 기록 칸 번호 (월요일 시작)
struct WeekdayIndexTests {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return cal
    }

    private func day(_ d: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: 12))!
    }

    @Test func mondayIsFirstAndSundayIsLast() {
        #expect(WeekdayIndex.mondayBased(day(26), calendar: calendar) == 0)   // 월
        #expect(WeekdayIndex.mondayBased(day(29), calendar: calendar) == 3)   // 목
        #expect(WeekdayIndex.mondayBased(day(25), calendar: calendar) == 6)   // 일
    }
}

// MARK: - 위젯 잠금 이유
@MainActor
struct WidgetLockReasonTests {
    @Test func widgetGuestScopeMatchesAppGuestScope() {
        #expect(WidgetAccountScope.guest == AccountPreferences.scope(for: LocalGuestIdentity.storageID))
    }

    @Test func lockReasonSaysWhyTheWidgetIsLocked() {
        let guest = AccountPreferences.scope(for: LocalGuestIdentity.storageID)
        let account = AccountPreferences.scope(for: UUID())

        #expect(WidgetLockReason.resolve(activeScope: nil, premiumScope: nil, premiumFlag: nil) == .needsAppOpen)
        #expect(WidgetLockReason.resolve(activeScope: guest, premiumScope: nil, premiumFlag: nil) == .signedOut)
        // 업데이트 직후: 이 계정의 Pro 여부가 아직 기록되지 않음
        #expect(WidgetLockReason.resolve(activeScope: account, premiumScope: nil, premiumFlag: true) == .needsAppOpen)
        #expect(WidgetLockReason.resolve(activeScope: account, premiumScope: account, premiumFlag: nil) == .needsAppOpen)
        // 다른 계정의 Pro는 이어받지 않음
        #expect(WidgetLockReason.resolve(activeScope: account, premiumScope: guest, premiumFlag: true) == .needsAppOpen)
        #expect(WidgetLockReason.resolve(activeScope: account, premiumScope: account, premiumFlag: false) == .needsPro)
        #expect(WidgetLockReason.resolve(activeScope: account, premiumScope: account, premiumFlag: true) == nil)
    }
}

// MARK: - 위젯 딥링크
@MainActor
struct WidgetDeepLinkTests {
    @Test func widgetLinksOpenTheirOwnTab() {
        #expect(WidgetDeepLink.tab(from: URL(string: "mora://tab/routine")!) == .routine)
        #expect(WidgetDeepLink.tab(from: URL(string: "mora://tab/planner")!) == .planner)
        #expect(WidgetDeepLink.tab(from: URL(string: "mora://tab/voice")!) == .voice)
        #expect(WidgetDeepLink.tab(named: "routine") == .routine)   // 앱 열기 Intent가 App Group에 남긴 이름
    }

    @Test func unknownLinksDoNotMoveTabs() {
        #expect(WidgetDeepLink.tab(from: URL(string: "mora://tab/unknown")!) == nil)
        #expect(WidgetDeepLink.tab(from: URL(string: "mora://tab")!) == nil)
        #expect(WidgetDeepLink.tab(from: URL(string: "mora://paywall")!) == nil)
        #expect(WidgetDeepLink.tab(from: URL(string: "https://tab/routine")!) == nil)
        #expect(WidgetDeepLink.tab(named: "") == nil)
    }

    @Test func inboxHandsOverTheLatestTabOnlyOnce() {
        WidgetDeepLinkInbox.store(.routine)
        WidgetDeepLinkInbox.store(.planner)
        #expect(WidgetDeepLinkInbox.take() == .planner)
        #expect(WidgetDeepLinkInbox.take() == nil)   // 화면을 다시 만들어도 예전 링크로 돌아가지 않음
    }
}
