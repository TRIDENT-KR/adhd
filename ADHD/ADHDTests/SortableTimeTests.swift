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
