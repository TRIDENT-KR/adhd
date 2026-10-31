import Testing
@testable import ADHD

// MARK: - TabPagerSync Tests
/// 탭 바 선택과 페이지형 TabView 화면이 어긋나지 않는지 검증
@MainActor
struct TabPagerSyncTests {

    /// 탭 바를 눌렀을 때 MainTabView가 하는 일: 넘길 페이지가 있으면 애니메이션으로 넘깁니다.
    private func tap(_ tab: TabSelection, sync: inout TabPagerSync, activeTab: inout TabSelection) {
        activeTab = tab
        if let page = sync.pageToShow(for: activeTab) {
            sync.beginMove(to: page, animated: true)
        }
    }

    @Test func tapMovesPagerToTappedTab() {
        var sync = TabPagerSync(tab: .voice)
        var activeTab = TabSelection.voice

        tap(.planner, sync: &sync, activeTab: &activeTab)

        #expect(sync.pagerTab == .planner)
        #expect(sync.movingTo == .planner)
        #expect(sync.pageDidSettle(.planner, activeTab: activeTab) == nil)
        #expect(sync.movingTo == nil)
    }

    /// 재현: Voice에서 Planner를 누르고, 넘어가는 중에 Voice를 누름
    @Test func secondTapDuringMoveIsAppliedAfterPageSettles() {
        var sync = TabPagerSync(tab: .voice)
        var activeTab = TabSelection.voice

        tap(.planner, sync: &sync, activeTab: &activeTab)
        tap(.voice, sync: &sync, activeTab: &activeTab)

        // 넘기는 중에는 TabView 선택을 다시 바꾸지 않습니다.
        #expect(activeTab == .voice)
        #expect(sync.pagerTab == .planner)

        // 화면 절반을 지날 때 TabView가 써 넣는 Planner는 탭 바를 되돌리지 않습니다.
        #expect(sync.pagerDidSelect(.planner) == nil)
        #expect(activeTab == .voice)

        // Planner에 멈추면 마지막으로 누른 Voice로 다시 넘깁니다.
        #expect(sync.pageDidSettle(.planner, activeTab: activeTab) == .showActiveTab)
        #expect(sync.pageToShow(for: activeTab) == .voice)
        sync.beginMove(to: .voice, animated: true)
        #expect(sync.pageDidSettle(.voice, activeTab: activeTab) == nil)
        #expect(sync.pagerTab == activeTab)
    }

    @Test func manyQuickTapsEndOnLastTappedTab() {
        var sync = TabPagerSync(tab: .voice)
        var activeTab = TabSelection.voice

        tap(.planner, sync: &sync, activeTab: &activeTab)
        tap(.routine, sync: &sync, activeTab: &activeTab)
        tap(.voice, sync: &sync, activeTab: &activeTab)
        tap(.routine, sync: &sync, activeTab: &activeTab)

        #expect(sync.pageDidSettle(.planner, activeTab: activeTab) == .showActiveTab)
        #expect(sync.pageToShow(for: activeTab) == .routine)
    }

    @Test func middlePagePassingByDuringTwoPageMoveIsIgnored() {
        var sync = TabPagerSync(tab: .routine)
        var activeTab = TabSelection.routine

        tap(.planner, sync: &sync, activeTab: &activeTab)

        // 루틴→플래너는 Voice를 지나갑니다. 그 순간의 선택·멈춤 신호는 탭 바에 반영하지 않습니다.
        #expect(sync.pagerDidSelect(.voice) == nil)
        #expect(sync.pageDidSettle(.voice, activeTab: activeTab) == nil)
        #expect(sync.movingTo == .planner)

        #expect(sync.pagerDidSelect(.planner) == nil)
        #expect(sync.pageDidSettle(.planner, activeTab: activeTab) == nil)
        #expect(sync.movingTo == nil)
    }

    @Test func swipeUpdatesTabBar() {
        var sync = TabPagerSync(tab: .voice)

        #expect(sync.pagerDidSelect(.planner) == .planner)
        #expect(sync.pageDidSettle(.planner, activeTab: .planner) == nil)
    }

    /// 앱이 넘기지 않았는데 탭 바와 다른 페이지에 멈추면 보이는 화면에 탭 바를 맞춥니다.
    @Test func pageSettlingOnOtherTabWhileIdleSelectsThatTab() {
        var sync = TabPagerSync(tab: .voice)

        #expect(sync.pageDidSettle(.planner, activeTab: .voice) == .selectTab(.planner))
        #expect(sync.pagerTab == .planner)
        #expect(sync.pageToShow(for: .planner) == nil)
    }

    @Test func moveWithoutAnimationDoesNotWait() {
        var sync = TabPagerSync(tab: .voice)

        sync.beginMove(to: .planner, animated: false)

        #expect(sync.movingTo == nil)
        #expect(sync.pageToShow(for: .routine) == .routine)
    }

    @Test func cancelledMoveUnblocksNextTap() {
        var sync = TabPagerSync(tab: .voice)
        var activeTab = TabSelection.voice

        tap(.planner, sync: &sync, activeTab: &activeTab)
        let move = sync.moveID
        tap(.voice, sync: &sync, activeTab: &activeTab)
        #expect(sync.isMoving(move))

        // 멈춤 신호가 오지 않아 시간이 지나면 기다림을 풀고 마지막 탭으로 넘깁니다.
        sync.cancelMove()
        #expect(!sync.isMoving(move))
        #expect(sync.pageToShow(for: activeTab) == .voice)
    }

    @Test func staleTimeoutDoesNotCancelNewerMove() {
        var sync = TabPagerSync(tab: .voice)
        var activeTab = TabSelection.voice

        tap(.planner, sync: &sync, activeTab: &activeTab)
        let firstMove = sync.moveID
        _ = sync.pageDidSettle(.planner, activeTab: activeTab)
        tap(.voice, sync: &sync, activeTab: &activeTab)

        #expect(!sync.isMoving(firstMove))
        #expect(sync.isMoving(sync.moveID))
    }
}
