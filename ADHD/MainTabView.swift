import SwiftUI

struct MainTabView: View {
    /// 탭 바와 각 화면이 보는 선택. 페이지형 TabView는 pager.pagerTab에 묶여 이 값을 따라갑니다.
    @State var activeTab: TabSelection = .voice
    @State private var pager = TabPagerSync(tab: .voice)
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @EnvironmentObject private var taskManager: TaskManager
    @EnvironmentObject private var authManager: AuthManager
    @ObservedObject private var langManager = LocalizationManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 한 번이라도 방문한 탭을 추적하여 지연 로딩
    @State private var loadedTabs: Set<TabSelection> = [.voice]
    /// HomeVoiceInterfaceView에서 모달이 열려 있는지 여부
    @State private var isVoiceModalVisible = false
    /// 이전 버전의 저장된 페이월 딥링크 호환.
    @State private var showPaywall = false
    @State private var isPlayingPresentationDemo = false
    @EnvironmentObject private var accountStoreController: AccountStoreController
    /// 로그인 직후 기기(게스트) 일정 가져오기 제안
    @State private var guestImportCount = 0
    @State private var showGuestImportOffer = false
    @State private var guestImportResult: String?
    /// 플래너를 아직 한 번도 열지 않았을 때 검색에서 고른 날짜. 플래너를 처음 만들 때 이 날로 엽니다.
    @State private var pendingPlannerDate: Date?
    /// 처음 탭을 정했는지. 그 전에 온 위젯 링크는 처음 탭을 정한 직후에 열어, 기본 탭에 덮이지 않게 합니다.
    @State private var didSetInitialTab = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // 1. 배경
            DesignSystem.Colors.background.ignoresSafeArea()

            // 2. 현재 탭 뷰 (스와이프 가능하도록 TabView 사용)
            TabView(selection: pagerSelection) {
                Group {
                    if loadedTabs.contains(.routine) {
                        RoutineView(activeTab: $activeTab)
                    } else {
                        Color.clear
                    }
                }
                .onPagerSettle(in: Self.pagerSpace) { pageDidSettle(.routine) }
                .tag(TabSelection.routine)

                HomeVoiceInterfaceView(activeTab: $activeTab, isModalVisible: $isVoiceModalVisible)
                    .onPagerSettle(in: Self.pagerSpace) { pageDidSettle(.voice) }
                    .tag(TabSelection.voice)

                Group {
                    if loadedTabs.contains(.planner) {
                        PlannerView(activeTab: $activeTab, initialDate: pendingPlannerDate)
                    } else {
                        Color.clear
                    }
                }
                .onPagerSettle(in: Self.pagerSpace) { pageDidSettle(.planner) }
                .tag(TabSelection.planner)
            }
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
            .coordinateSpace(.named(Self.pagerSpace))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 80)
            .onChange(of: activeTab) { _, newTab in
                if !loadedTabs.contains(newTab) {
                    loadedTabs.insert(newTab)
                }
                showActiveTabPage()
            }
            .accessibilityElement(children: .contain)

            // 3. 글로벌 바텀 바
            CustomBottomBar(activeTab: $activeTab)
                .blur(radius: isVoiceModalVisible ? 12 : 0)
                .opacity(isVoiceModalVisible ? 0.6 : 1)
                .animation(reduceMotion ? .none : .spring(response: 0.4, dampingFraction: 0.7), value: isVoiceModalVisible)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if case .lockedInvalidSession = authManager.accessState {
                Text(L.authRelease.sessionExpired)
                    .font(.footnote)
                    .foregroundStyle(DesignSystem.Colors.onSurfaceVariant)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(DesignSystem.Colors.surfaceContainerLow)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        // 4. 오프라인 / Back Online 배너
        .overlay(alignment: .top) {
            if networkMonitor.isOfflineBannerVisible {
                OfflineBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if networkMonitor.isBackOnlineBannerVisible {
                BackOnlineBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(
            reduceMotion ? .none : .spring(response: 0.4, dampingFraction: 0.75),
            value: networkMonitor.bannerState
        )
        // 5. Undo 스낵바
        .overlay(alignment: .bottom) {
            if taskManager.showUndoSnackbar {
                UndoSnackbar(
                    message: taskManager.undoSnackbarMessage,
                    onUndo: { taskManager.undo() }
                )
                .padding(.bottom, 100)
                .padding(.horizontal, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(
            reduceMotion ? .none : .spring(response: 0.4, dampingFraction: 0.7),
            value: taskManager.showUndoSnackbar
        )
        // 잠깐 떴다 사라지는 안내는 VoiceOver 사용자에게 소리로 알려 줍니다.
        .onChange(of: taskManager.showUndoSnackbar) { _, isShown in
            guard isShown else { return }
            AccessibilityNotification.Announcement(taskManager.undoSnackbarMessage).post()
        }
        .onChange(of: networkMonitor.bannerState) { _, _ in
            if networkMonitor.isOfflineBannerVisible {
                AccessibilityNotification.Announcement(L.offlineText).post()
            } else if networkMonitor.isBackOnlineBannerVisible {
                AccessibilityNotification.Announcement(L.network.backOnline).post()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .widgetDeepLink)) { notification in
            // 위젯 링크는 처음 탭을 정한 뒤에만 꺼냅니다. 그 전이면 아래 .task가 엽니다.
            let widgetTab = didSetInitialTab ? WidgetDeepLinkInbox.take() : nil
            if let tab = (notification.object as? TabSelection) ?? widgetTab {
                if !loadedTabs.contains(tab) {
                    loadedTabs.insert(tab)
                }
                withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.3)) { activeTab = tab }
            }
        }
        // 플래너가 이미 있으면 PlannerView가 직접 받습니다. 아직 없으면 그 날짜로 처음 만듭니다.
        .onReceive(NotificationCenter.default.publisher(for: .plannerJumpToDate)) { notification in
            guard let date = notification.object as? Date, !loadedTabs.contains(.planner) else { return }
            pendingPlannerDate = date
            loadedTabs.insert(.planner)
        }
        // 6. 강한 알림 오버레이: 시트가 떠 있어도 보이도록 별도 창(AlarmOverlayWindowPresenter)에 띄웁니다.
        .onAppear { AlarmOverlayWindowPresenter.shared.start() }
        // 7. 이전 버전의 페이월 딥링크 호환
        .onReceive(NotificationCenter.default.publisher(for: .openPaywall)) { _ in
            showPaywall = true
        }
        .sheet(isPresented: $showPaywall) {
            NavigationView { PaywallView() }
        }
        // 8. Apple로 로그인한 직후: 계정이 비어 있고 기기에 게스트 일정이 있을 때 한 번 가져오기를 제안
        //    익명 계정은 기기 일정을 그대로 쓰므로 제안하지 않습니다.
        .task(id: authManager.accessState.exposedUserID) {
            offerGuestImportIfNeeded()
        }
        .alert(L.authRelease.importGuestTitle, isPresented: $showGuestImportOffer) {
            Button(L.authRelease.importGuestAction) { importGuestTasks() }
            Button(L.authRelease.importGuestLater, role: .cancel) {}
        } message: {
            Text(L.authRelease.importGuestMessage(guestImportCount))
        }
        .alert(L.authRelease.copyGuestTasks, isPresented: Binding(
            get: { guestImportResult != nil },
            set: { if !$0 { guestImportResult = nil } }
        )) {
            Button(L.settings.done) { guestImportResult = nil }
        } message: {
            Text(guestImportResult ?? "")
        }
        .task {
            // 처음 탭을 정하기 전에 위젯을 눌러 들어왔다면(콜드 런치 등) 그 위젯의 탭을 엽니다.
            didSetInitialTab = true
            if let widgetTab = WidgetDeepLinkInbox.take() {
                loadedTabs.insert(widgetTab)
                activeTab = widgetTab
                // 처음 화면이므로 넘기는 애니메이션 없이 바로 엽니다.
                showActiveTabPage(animated: false)
            }
            guard MoraApp.presentationDemoMode, !isPlayingPresentationDemo else { return }
            isPlayingPresentationDemo = true
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            withAnimation { activeTab = .routine }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            withAnimation { activeTab = .planner }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            withAnimation { activeTab = .voice }
        }
    }
}

extension MainTabView {
    /// Apple로 로그인하면 게스트 일정의 알림이 멈추므로, 계정이 비어 있을 때 한 번만 가져오기를 묻습니다.
    /// 이미 일정이 있는 계정이거나 한 번 물어본 계정은 설정의 '기기 일정을 이 계정으로 복사'를 씁니다.
    /// 익명 계정은 기기 저장소를 그대로 쓰므로(exposedUserID == nil) 묻지 않습니다.
    fileprivate func offerGuestImportIfNeeded() {
        guard let userID = authManager.accessState.exposedUserID,
              accountStoreController.activeUserID == userID,
              !AccountPreferences.bool(.guestImportOffered, default: false, for: userID),
              accountStoreController.activeTaskCount() == 0 else { return }
        let count = accountStoreController.guestTaskCountNotInActiveAccount()
        guard count > 0 else { return }
        AccountPreferences.set(true, for: .guestImportOffered, userID: userID)
        guestImportCount = count
        showGuestImportOffer = true
    }

    fileprivate func importGuestTasks() {
        guard let userID = authManager.accessState.exposedUserID else { return }
        do {
            let count = try accountStoreController.copyGuestTasks(to: userID)
            taskManager.reconcileNotificationsWithPreferences()
            taskManager.writeWidgetSnapshot()
            guestImportResult = L.authRelease.copiedGuestTasks(count)
        } catch {
            guestImportResult = L.authRelease.copyGuestFailed
        }
    }
}

// MARK: - Tab Pager
extension MainTabView {
    fileprivate static let pagerSpace = "MainTabPager"
    /// DESIGN.md 전환 곡선(300ms, 0.4/0/0.2/1). 탄성 애니메이션은 목표 페이지를 지나쳤다 돌아와 쓰지 않습니다.
    fileprivate static let pageAnimation = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.3)
    /// 넘기던 페이지가 멈췄다는 신호가 이 시간 안에 오지 않으면 기다림을 풉니다.
    /// 플래너를 처음 열 때는 화면을 만드느라 0.5초 가까이 걸려서 넉넉히 잡습니다.
    fileprivate static let pageMoveTimeout: TimeInterval = 1.5

    /// TabView가 읽고 쓰는 선택. 사용자가 스와이프해서 바꾼 값만 탭 바(activeTab)에 반영합니다.
    fileprivate var pagerSelection: Binding<TabSelection> {
        Binding(
            get: { pager.pagerTab },
            set: { tab in
                if let swiped = pager.pagerDidSelect(tab), swiped != activeTab {
                    activeTab = swiped
                }
            }
        )
    }

    /// TabView를 activeTab 페이지로 넘깁니다. 이미 넘기는 중이면 그 페이지가 멈춘 뒤에 넘어갑니다.
    fileprivate func showActiveTabPage(animated: Bool = true) {
        guard let tab = pager.pageToShow(for: activeTab) else { return }
        let animated = animated && !reduceMotion
        withAnimation(animated ? Self.pageAnimation : nil) {
            pager.beginMove(to: tab, animated: animated)
        }
        guard animated else { return }
        let move = pager.moveID
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pageMoveTimeout) {
            guard pager.isMoving(move) else { return }
            pager.cancelMove()
            showActiveTabPage()
        }
    }

    fileprivate func pageDidSettle(_ tab: TabSelection) {
        switch pager.pageDidSettle(tab, activeTab: activeTab) {
        case .showActiveTab?:
            // 멈춘 직후의 같은 업데이트에서 선택을 바꾸면 TabView가 놓칠 수 있어 한 박자 뒤에 넘깁니다.
            DispatchQueue.main.async { showActiveTabPage() }
        case .selectTab(let visible)?:
            activeTab = visible
        case nil:
            break
        }
    }
}

/// 탭 바 선택(activeTab)과 페이지형 TabView가 보여 주는 화면을 맞춥니다.
///
/// 페이지가 넘어가는 도중에 TabView 선택을 다시 바꾸면, TabView가 새 선택을 놓치고 화면 절반을 지나는 순간
/// 이전 탭을 다시 써 넣어 탭 바와 화면이 어긋납니다(Voice에서 Planner를 누르고 바로 Voice).
/// 그래서 앱이 페이지를 넘기는 동안에는 TabView 선택을 건드리지 않고, 그 페이지가 멈춘 뒤
/// 그사이 마지막으로 고른 탭으로 한 번 더 넘깁니다.
struct TabPagerSync {
    /// TabView에 묶인 선택
    private(set) var pagerTab: TabSelection
    /// 앱이 넘기고 있는 페이지. 이 페이지가 화면에 멈출 때까지 TabView 선택을 바꾸지 않습니다.
    private(set) var movingTo: TabSelection?
    /// 넘기기마다 늘어나는 번호. 늦게 도착한 시간 초과가 새 넘기기를 끊지 않게 합니다.
    private(set) var moveID = 0

    enum Follow: Equatable {
        /// 넘기는 동안 다른 탭을 골랐으니 TabView를 activeTab 페이지로 다시 넘깁니다.
        case showActiveTab
        /// 앱이 넘기지 않았는데 다른 페이지에 멈췄으니 탭 바를 보이는 화면에 맞춥니다.
        case selectTab(TabSelection)
    }

    init(tab: TabSelection) {
        pagerTab = tab
    }

    /// activeTab을 보여 주려고 지금 넘길 페이지. 이미 그 페이지이거나 다른 페이지로 넘기는 중이면 nil.
    func pageToShow(for activeTab: TabSelection) -> TabSelection? {
        guard movingTo == nil, pagerTab != activeTab else { return nil }
        return activeTab
    }

    /// TabView 선택을 tab으로 바꿉니다. 애니메이션으로 넘기면 그 페이지가 멈출 때까지 기다립니다.
    mutating func beginMove(to tab: TabSelection, animated: Bool) {
        pagerTab = tab
        movingTo = animated ? tab : nil
        moveID += 1
    }

    func isMoving(_ move: Int) -> Bool {
        movingTo != nil && moveID == move
    }

    /// 멈췄다는 신호가 오지 않을 때 기다림을 풀어, 다음 선택이 영영 막히지 않게 합니다.
    mutating func cancelMove() {
        movingTo = nil
    }

    /// TabView가 선택을 써 넣었습니다. 사용자가 스와이프한 것이면 탭 바에 반영할 탭을 돌려줍니다.
    /// 앱이 넘기는 중에 써 넣는 값(화면 절반을 지날 때, 두 칸 넘길 때 가운데 페이지)은 반영하지 않습니다.
    mutating func pagerDidSelect(_ tab: TabSelection) -> TabSelection? {
        pagerTab = tab
        return movingTo == nil ? tab : nil
    }

    /// 페이지 tab이 화면에 꼭 맞게 멈췄습니다.
    mutating func pageDidSettle(_ tab: TabSelection, activeTab: TabSelection) -> Follow? {
        let finishedMove = movingTo != nil
        if let target = movingTo {
            // 두 칸을 넘길 때 가운데 페이지가 잠깐 화면에 맞는 순간은 무시합니다.
            guard tab == target else { return nil }
            movingTo = nil
        }
        pagerTab = tab
        guard tab != activeTab else { return nil }
        return finishedMove ? .showActiveTab : .selectTab(tab)
    }
}

private extension View {
    /// 페이지형 TabView 안의 페이지가 화면에 꼭 맞게 멈추면 알려 줍니다.
    func onPagerSettle(in space: String, perform action: @escaping () -> Void) -> some View {
        onGeometryChange(for: Bool.self) { proxy in
            abs(proxy.frame(in: .named(space)).minX) < 1
        } action: { isSettled in
            if isSettled { action() }
        }
    }
}

// MARK: - Widget Deep Link
/// 위젯 링크(mora://tab/routine)를 앱 탭으로 바꿉니다.
enum WidgetDeepLink {
    /// mora://tab/<이름>만 받습니다. 모르는 링크는 nil이라 탭을 바꾸지 않습니다.
    static func tab(from url: URL) -> TabSelection? {
        guard url.scheme?.lowercased() == "mora", url.host?.lowercased() == "tab" else { return nil }
        return tab(named: url.lastPathComponent)
    }

    static func tab(named name: String) -> TabSelection? {
        switch name.lowercased() {
        case "routine": return .routine
        case "planner": return .planner
        case "voice":   return .voice
        default:        return nil
        }
    }
}

/// 위젯에서 고른 탭을 메인 화면이 뜰 때까지 들고 있습니다.
/// 앱이 꺼져 있을 때 위젯을 누르면 링크가 로딩 화면 중에 도착해, 알림만 보내면 받을 화면이 없기 때문입니다.
enum WidgetDeepLinkInbox {
    private static var pendingTab: TabSelection?

    static func store(_ tab: TabSelection) {
        pendingTab = tab
    }

    /// 기다리던 탭을 꺼냅니다. 꺼내면 비워서, 화면을 다시 만들 때 예전 링크로 돌아가지 않게 합니다.
    static func take() -> TabSelection? {
        defer { pendingTab = nil }
        return pendingTab
    }
}

// MARK: - Widget Deep Link Notification
extension Notification.Name {
    /// 탭을 옮깁니다. object가 TabSelection이면 그 탭으로(검색 결과), 없으면 WidgetDeepLinkInbox에서 꺼냅니다(위젯).
    static let widgetDeepLink = Notification.Name("widgetDeepLink")
    /// 플래너의 선택 날짜를 옮깁니다 (object: Date). 검색 결과에서 일정을 고를 때 씁니다.
    static let plannerJumpToDate = Notification.Name("plannerJumpToDate")
    /// 이전 버전의 mora://paywall 링크 호환.
    static let openPaywall = Notification.Name("openPaywall")
}

// MARK: - Undo Snackbar
struct UndoSnackbar: View {
    let message: String
    let onUndo: () -> Void

    // D24: 중성 회색 금지(디자인 금기 #1) — 에러 토스트와 동일 계열의 웜 브라운
    private static let backgroundColor = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(r: 0x3A, g: 0x2A, b: 0x22)
            : UIColor(r: 0x4A, g: 0x30, b: 0x25)
    })

    var body: some View {
        HStack(spacing: 12) {
            Text(message)
                .font(.footnote.weight(.medium))
                .foregroundColor(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.8)

            Spacer()

            Button(action: onUndo) {
                Text(L.voice.undoButton)
                    .font(.footnote.weight(.bold))
                    .foregroundColor(DesignSystem.Colors.primaryFixedDim)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(L.voice.a11yUndo)
            .accessibilityHint(L.t("Double tap to undo the last action", "마지막 작업을 되돌리려면 이중 탭하세요", "最後の操作を取り消すにはダブルタップ"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Self.backgroundColor)
        )
    }
}

// MARK: - Offline Banner
private struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.footnote.weight(.semibold))
            Text(L.offlineText)
                .font(DesignSystem.Typography.labelSm)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(DesignSystem.Colors.background)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DesignSystem.Colors.onSurfaceVariant.opacity(0.92))
        )
        .padding(.horizontal, 24)
        .padding(.top, 56) // 노치/Dynamic Island 회피
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L.offlineText)
        .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - Back Online Banner
private struct BackOnlineBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi")
                .font(.footnote.weight(.semibold))
            Text(L.network.backOnline)
                .font(DesignSystem.Typography.labelSm)
        }
        .foregroundColor(DesignSystem.Colors.onTertiary)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DesignSystem.Colors.tertiary.opacity(0.92))
        )
        .padding(.horizontal, 24)
        .padding(.top, 56)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L.network.backOnline)
        .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - Preview
struct MainTabView_Previews: PreviewProvider {
    static var previews: some View {
        MainTabView()
            .environmentObject(NetworkMonitor.shared)
    }
}
