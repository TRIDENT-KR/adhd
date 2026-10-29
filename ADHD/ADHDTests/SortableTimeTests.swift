import Testing
import Foundation
@testable import ADHD

// MARK: - AppTask.sortableTime Tests
/// "hh:mm a"/"h:mm a"/"HH:mm" → 24시간 정렬 키 변환 검증
struct SortableTimeTests {

    private func task(time: String?) -> AppTask {
        AppTask(task: "t", time: time, category: "Routine")
    }

    @Test func convertsTwelveHourPM() {
        #expect(task(time: "02:00 PM").sortableTime == "14:00")
    }

    @Test func convertsSingleDigitHourAM() {
        #expect(task(time: "9:05 AM").sortableTime == "09:05")
    }

    @Test func keepsTwentyFourHourFormat() {
        #expect(task(time: "14:00").sortableTime == "14:00")
    }

    @Test func nilAndEmptySortLast() {
        #expect(task(time: nil).sortableTime == "99:99")
        #expect(task(time: "").sortableTime == "99:99")
    }

    @Test func unparsableStringReturnsOriginal() {
        #expect(task(time: "아무때나").sortableTime == "아무때나")
    }

    @Test func sortingPutsMorningFirstAndNoTimeLast() {
        let times = [task(time: nil), task(time: "02:00 PM"), task(time: "09:00 AM")]
        let sorted = times.sorted { $0.sortableTime < $1.sortableTime }
        #expect(sorted[0].time == "09:00 AM")
        #expect(sorted[1].time == "02:00 PM")
        #expect(sorted[2].time == nil)
    }
}

// MARK: - StoredTaskFormat Tests
/// 확인 카드 편집 저장값이 기기 언어와 무관하게 알림·정렬이 읽는 형식인지 검증
@MainActor
struct StoredTaskFormatTests {

    private func date(hour: Int, minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: hour, minute: minute))!
    }

    @Test func storesTimeInPosixTwelveHourFormat() {
        let stored = StoredTaskFormat.time.string(from: date(hour: 15, minute: 0))
        #expect(stored == "03:00 PM")
        #expect(AppTask(task: "t", time: stored, category: "Routine").sortableTime == "15:00")
    }

    @Test func storesDateWithGregorianYear() {
        #expect(StoredTaskFormat.date.string(from: date(hour: 9, minute: 0)) == "2026-10-29")
    }

    private func hm(_ string: String) -> String? {
        StoredTaskFormat.hourMinute(from: string).map { "\($0.hour):\($0.minute)" }
    }

    @Test func readsEveryStoredTimeShape() {
        #expect(hm("03:00 PM") == "15:0")
        #expect(hm("9:05 AM") == "9:5")
        #expect(hm("14:30") == "14:30")
        #expect(hm("12:00 AM") == "0:0")
    }

    @Test func rejectsDeviceLocaleTimeAndEmptyString() {
        #expect(hm("오후 3:00") == nil)
        #expect(hm("") == nil)
    }
}

// MARK: - 새 항목 자리 (순서를 바꾼 목록에서도 시간에 맞게)
@MainActor
struct NewTaskPlacementTests {

    private func task(_ time: String?, order: Int) -> AppTask {
        AppTask(task: "t", time: time, category: "Routine", sortOrder: order)
    }

    private func displayOrder(_ tasks: [AppTask]) -> [String?] {
        tasks.sorted { a, b in
            if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
            return a.sortableTime < b.sortableTime
        }.map(\.time)
    }

    @Test func untouchedListKeepsTimeOrder() {
        let peers = [task("09:00 AM", order: 0), task("06:00 PM", order: 0)]
        #expect(TaskManager.placementSortOrder(forSortableTime: "12:00", among: peers) == 0)
    }

    @Test func reorderedListPlacesNewTaskBeforeFirstLaterOne() {
        let peers = [task("09:00 AM", order: 10), task("06:00 PM", order: 20), task("08:00 PM", order: 30)]
        let new = task("12:00 PM", order: 0)
        new.sortOrder = TaskManager.placementSortOrder(forSortableTime: new.sortableTime, among: peers)
        #expect(displayOrder(peers + [new]) == ["09:00 AM", "12:00 PM", "06:00 PM", "08:00 PM"])
    }

    @Test func latestOrUntimedTaskGoesLast() {
        let peers = [task("09:00 AM", order: 10), task("06:00 PM", order: 20)]
        #expect(TaskManager.placementSortOrder(forSortableTime: "21:00", among: peers) == 30)
        #expect(TaskManager.placementSortOrder(forSortableTime: "99:99", among: peers) == 30)
    }
}
