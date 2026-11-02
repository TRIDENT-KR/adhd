import Combine
import EventKit
import SwiftData
import SwiftUI
import UIKit

// MARK: - DeviceCalendar
/// 아이폰 캘린더와 모라를 잇습니다. iPhone 설정에 추가한 iCloud·구글·Outlook 일정이 모두 여기로 들어옵니다.
/// - 보기: 플래너에 그날의 기기 일정을 함께 보여 줍니다.
/// - 내보내기: 모라의 일정(Appointment)을 기기 캘린더의 'Mora' 캘린더에 맞춰 둡니다. 모라가 원본이라
///   모라에서 고치거나 지우면 캘린더도 따라갑니다.
/// 캘린더 내용은 기기 안에서만 쓰고 서버나 AI로 보내지 않습니다.
@MainActor
final class DeviceCalendar: ObservableObject {
    static let shared = DeviceCalendar()

    enum Feature: String {
        case showEvents
        case exportAppointments

        var preferenceKey: AccountPreferenceKey {
            switch self {
            case .showEvents: return .calendarShowsEvents
            case .exportAppointments: return .calendarExportsAppointments
            }
        }
    }

    /// 플래너에 보여 줄 기기 일정 한 건
    struct Event: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let color: Color
    }

    @Published private(set) var showsEvents = false
    @Published private(set) var exportsAppointments = false
    /// 기기 캘린더나 설정이 바뀔 때마다 올라갑니다. 플래너는 이 값이 바뀌면 일정을 다시 읽습니다.
    @Published private(set) var revision = 0

    private let store = EKEventStore()
    private let defaults: UserDefaults
    private var storeChange: AnyCancellable?

    /// 내보낸 일정은 기기마다 기록합니다. 캘린더가 iCloud로 공유돼도 이 기기가 넣은 것만 고치고 지웁니다.
    private enum Key {
        static let exported = "mora.calendar.exportedEvents.v1"
        static let calendarID = "mora.calendar.moraCalendarID.v1"
        static let pendingFeature = "mora.calendar.pendingFeature.v1"
    }

    private struct ExportRecord: Codable {
        let eventID: String
        let signature: String
    }

    /// 시간만 있는 모라 일정은 캘린더에 이만큼의 칸으로 넣습니다.
    static let exportedEventDuration: TimeInterval = 30 * 60
    private static let moraColor = CGColor(srgbRed: 0x93 / 255, green: 0x4A / 255, blue: 0x2E / 255, alpha: 1)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storeChange = NotificationCenter.default.publisher(for: .EKEventStoreChanged, object: store)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.revision += 1 }
        reloadPreferences()
    }

    var hasFullAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// 이미 거절했거나 '추가만 허용'이라, iPhone 설정에서 직접 켜야 하는 상태인지
    var needsSettingsForAccess: Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .denied, .writeOnly: return true
        default: return false
        }
    }

    /// 계정 설정과 권한을 다시 읽습니다. 값이 바뀐 경우에만 화면을 갱신합니다.
    func reloadPreferences() {
        let access = hasFullAccess
        let shows = access && AccountPreferences.bool(.calendarShowsEvents, default: false)
        let exports = access && AccountPreferences.bool(.calendarExportsAppointments, default: false)
        guard shows != showsEvents || exports != exportsAppointments else { return }
        showsEvents = shows
        exportsAppointments = exports
        revision += 1
    }

    /// 켜기 전에 캘린더 전체 접근을 받습니다. 받지 못하면 false이고 설정은 그대로 둡니다.
    @discardableResult
    func set(_ feature: Feature, enabled: Bool) async -> Bool {
        if enabled, !(await requestFullAccess()) { return false }
        AccountPreferences.set(enabled, for: feature.preferenceKey)
        reloadPreferences()
        if feature == .exportAppointments, !enabled {
            removeExportedEvents()
        }
        return true
    }

    /// 권한을 거절해 둔 상태라 iPhone 설정을 엽니다. 권한을 바꾸면 iOS가 앱을 다시 시작하므로,
    /// 켜려던 기능을 적어 두었다가 돌아와 권한이 있으면 마저 켭니다.
    func openSettingsToAllowAccess(for feature: Feature) {
        defaults.set(feature.rawValue, forKey: Key.pendingFeature)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    /// 설정에서 권한을 켜고 돌아왔다면 켜려던 기능을 켭니다. 권한 없이 돌아왔다면 잊습니다.
    private func resolvePendingAccess() {
        guard let raw = defaults.string(forKey: Key.pendingFeature) else { return }
        defaults.removeObject(forKey: Key.pendingFeature)
        guard hasFullAccess, let feature = Feature(rawValue: raw) else { return }
        AccountPreferences.set(true, for: feature.preferenceKey)
    }

    private func requestFullAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return true
        case .notDetermined:
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            // 권한을 받은 직후에는 캘린더 목록을 새로 읽어야 합니다.
            if granted { store.reset() }
            return granted
        default:
            return false
        }
    }

    // MARK: - 보기

    /// 그날의 기기 일정. 하루 종일 일정을 먼저, 나머지는 시작 시간순입니다.
    func events(on day: Date, calendar: Calendar = .current) -> [Event] {
        guard showsEvents else { return [] }
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return deviceEvents(from: start, to: end)
            .map { event in
                Event(
                    id: "\(event.calendarItemIdentifier)-\(event.startDate.timeIntervalSince1970)",
                    title: event.title?.isEmpty == false
                        ? event.title : L.t("(No title)", "(제목 없음)", "(タイトルなし)"),
                    start: event.startDate,
                    end: event.endDate,
                    isAllDay: event.isAllDay,
                    color: Color(cgColor: event.calendar.cgColor)
                )
            }
            .sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
    }

    /// 기간 안에서 기기 일정이 있는 날들 (날짜 바의 점 표시용)
    func eventDays(from start: Date, to end: Date, calendar: Calendar = .current) -> Set<Date> {
        guard showsEvents else { return [] }
        var days = Set<Date>()
        for event in deviceEvents(from: start, to: end) {
            var day = calendar.startOfDay(for: max(event.startDate, start))
            // 자정에 끝나는 일정이 다음 날에 점을 찍지 않게 1초 당깁니다.
            let last = min(max(event.endDate.addingTimeInterval(-1), event.startDate), end)
            while day <= last {
                days.insert(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return days
    }

    private func deviceEvents(from start: Date, to end: Date) -> [EKEvent] {
        let moraCalendarID = defaults.string(forKey: Key.calendarID)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).filter { event in
            // 모라가 넣은 일정은 이미 모라 카드로 보이므로 다시 보여 주지 않습니다. 거절한 초대도 뺍니다.
            event.calendar?.calendarIdentifier != moraCalendarID
                && event.url?.scheme != "mora"
                && !(event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false)
        }
    }

    // MARK: - 내보내기

    /// 모라 일정을 기기 캘린더에 맞춥니다. 바뀐 일정만 다시 쓰고, 모라에서 지운 일정은 캘린더에서도 지웁니다.
    /// 내보내기가 꺼져 있는데 넣어 둔 일정이 남아 있으면(계정을 바꾼 경우 등) 그것을 거둡니다.
    func syncExport(_ tasks: [AppTask]) {
        resolvePendingAccess()
        reloadPreferences()
        guard hasFullAccess else { return }
        guard exportsAppointments else {
            if !loadExported().isEmpty || defaults.string(forKey: Key.calendarID) != nil {
                removeExportedEvents()
            }
            return
        }
        guard let target = exportCalendar() else { return }

        var exported = loadExported()
        var wantedIDs = Set<String>()
        var createdSeries: [(event: EKEvent, skippedDayKeys: [String])] = []
        var changed = false

        for task in tasks where task.category == "Appointment" && task.date != nil && !task.isDeleted {
            let key = task.id.uuidString
            wantedIDs.insert(key)
            let signature = Self.signature(of: task)
            let existing = exported[key].flatMap { store.calendarItem(withIdentifier: $0.eventID) as? EKEvent }
            if existing != nil, exported[key]?.signature == signature { continue }
            do {
                // 반복 일정은 첫 회차부터 통째로 바꿔야 해서, 고칠 때는 지우고 새로 넣습니다.
                if let existing { try store.remove(existing, span: .futureEvents, commit: false) }
                let event = makeEvent(for: task, in: target)
                try store.save(event, span: .futureEvents, commit: false)
                exported[key] = ExportRecord(eventID: event.calendarItemIdentifier, signature: signature)
                if task.isRecurring, !task.skippedDayKeys.isEmpty {
                    createdSeries.append((event, task.skippedDayKeys))
                }
                changed = true
            } catch {
                print("calendar_export_failed")
            }
        }

        for (key, record) in exported where !wantedIDs.contains(key) {
            if let event = store.calendarItem(withIdentifier: record.eventID) as? EKEvent {
                try? store.remove(event, span: .futureEvents, commit: false)
                changed = true
            }
            exported[key] = nil
        }

        guard changed else {
            saveExported(exported)
            return
        }
        do {
            try store.commit()
        } catch {
            store.reset()
            print("calendar_export_commit_failed")
            return
        }
        saveExported(exported)
        // 건너뛴 회차는 시리즈를 저장한 뒤에야 찾을 수 있어서 따로 지웁니다.
        removeSkippedOccurrences(createdSeries)
    }

    /// 넣어 둔 일정을 기기 캘린더에서 모두 거둡니다. 모라가 만든 캘린더는 통째로 지웁니다.
    func removeExportedEvents() {
        guard hasFullAccess else { return }
        for record in loadExported().values {
            if let event = store.calendarItem(withIdentifier: record.eventID) as? EKEvent {
                try? store.remove(event, span: .futureEvents, commit: false)
            }
        }
        if let id = defaults.string(forKey: Key.calendarID), let calendar = store.calendar(withIdentifier: id) {
            try? store.removeCalendar(calendar, commit: false)
        }
        do {
            try store.commit()
        } catch {
            store.reset()
            print("calendar_export_remove_failed")
            return
        }
        defaults.removeObject(forKey: Key.exported)
        defaults.removeObject(forKey: Key.calendarID)
    }

    /// 내보낼 캘린더. 처음엔 'Mora' 캘린더를 만들고, 만들 수 없는 계정뿐이면 기본 캘린더를 씁니다.
    private func exportCalendar() -> EKCalendar? {
        if let id = defaults.string(forKey: Key.calendarID), let existing = store.calendar(withIdentifier: id) {
            return existing
        }
        // 기본 캘린더와 같은 계정(대개 iCloud)에 만들어야 다른 기기와 캘린더 앱에서도 보입니다.
        var sources: [EKSource] = []
        if let source = store.defaultCalendarForNewEvents?.source { sources.append(source) }
        sources += store.sources.filter { $0.sourceType == .calDAV && $0.title == "iCloud" }
        sources += store.sources.filter { $0.sourceType == .local }
        for source in sources {
            let calendar = EKCalendar(for: .event, eventStore: store)
            calendar.title = "Mora"
            calendar.cgColor = Self.moraColor
            calendar.source = source
            do {
                try store.saveCalendar(calendar, commit: true)
                defaults.set(calendar.calendarIdentifier, forKey: Key.calendarID)
                return calendar
            } catch {
                continue
            }
        }
        return store.defaultCalendarForNewEvents
    }

    /// 모라가 직접 알림을 보내므로 캘린더 알림은 넣지 않습니다 (두 번 울리지 않게).
    private func makeEvent(for task: AppTask, in calendar: EKCalendar) -> EKEvent {
        let cal = Calendar.current
        let day = cal.startOfDay(for: task.date ?? Date())
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = task.task
        // 캘린더 앱에서 링크를 누르면 모라 플래너가 열립니다. 뒤의 task는 어느 일정인지 알아보는 표시입니다.
        event.url = URL(string: "mora://tab/planner?task=\(task.id.uuidString)")
        if let clock = task.time.flatMap(StoredTaskFormat.hourMinute(from:)),
           let start = cal.date(bySettingHour: clock.hour, minute: clock.minute, second: 0, of: day) {
            event.startDate = start
            event.endDate = start.addingTimeInterval(Self.exportedEventDuration)
        } else {
            event.isAllDay = true
            event.startDate = day
            event.endDate = day
        }
        if let rule = Self.recurrenceRule(for: task.recurrenceRule) {
            event.recurrenceRules = [rule]
        }
        return event
    }

    private func removeSkippedOccurrences(_ series: [(event: EKEvent, skippedDayKeys: [String])]) {
        guard !series.isEmpty else { return }
        let cal = Calendar.current
        var removed = false
        for item in series {
            for key in item.skippedDayKeys {
                guard let day = StoredTaskFormat.date.date(from: key) else { continue }
                let start = cal.startOfDay(for: day)
                guard let end = cal.date(byAdding: .day, value: 1, to: start) else { continue }
                let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [item.event.calendar])
                for occurrence in store.events(matching: predicate)
                where occurrence.calendarItemIdentifier == item.event.calendarItemIdentifier {
                    try? store.remove(occurrence, span: .thisEvent, commit: false)
                    removed = true
                }
            }
        }
        guard removed else { return }
        do { try store.commit() } catch {
            store.reset()
            print("calendar_export_skip_failed")
        }
    }

    /// 캘린더에 쓰는 값이 같으면 다시 쓰지 않도록 비교하는 요약입니다.
    static func signature(of task: AppTask) -> String {
        [
            "v1",
            task.task,
            task.date.map(AppTask.dayKey) ?? "",
            task.time.flatMap(StoredTaskFormat.hourMinute(from:)).map { "\($0.hour):\($0.minute)" } ?? "",
            task.recurrenceRule ?? "",
            task.isRecurring ? task.skippedDayKeys.sorted().joined(separator: ",") : "",
        ].joined(separator: "|")
    }

    static func recurrenceRule(for rule: String?) -> EKRecurrenceRule? {
        switch rule {
        case "weekly": return EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)
        case "biweekly": return EKRecurrenceRule(recurrenceWith: .weekly, interval: 2, end: nil)
        case "monthly": return EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil)
        case "yearly": return EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil)
        default: return nil
        }
    }

    private func loadExported() -> [String: ExportRecord] {
        guard let data = defaults.data(forKey: Key.exported) else { return [:] }
        return (try? JSONDecoder().decode([String: ExportRecord].self, from: data)) ?? [:]
    }

    private func saveExported(_ records: [String: ExportRecord]) {
        if records.isEmpty {
            defaults.removeObject(forKey: Key.exported)
        } else {
            defaults.set(try? JSONEncoder().encode(records), forKey: Key.exported)
        }
    }
}
