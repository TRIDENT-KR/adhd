import SwiftUI

struct MainTabView: View {
    @State var activeTab: TabSelection = .voice
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

    var body: some View {
        ZStack(alignment: .bottom) {
            // 1. 배경
            DesignSystem.Colors.background.ignoresSafeArea()

            // 2. 현재 탭 뷰 (스와이프 가능하도록 TabView 사용)
            TabView(selection: $activeTab) {
                Group {
                    if loadedTabs.contains(.routine) {
                        RoutineView(activeTab: $activeTab)
                    } else {
                        Color.clear
                    }
                }
                .tag(TabSelection.routine)

                HomeVoiceInterfaceView(activeTab: $activeTab, isModalVisible: $isVoiceModalVisible)
                    .tag(TabSelection.voice)

                Group {
                    if loadedTabs.contains(.planner) {
                        PlannerView(activeTab: $activeTab, initialDate: pendingPlannerDate)
                    } else {
                        Color.clear
                    }
                }
                .tag(TabSelection.planner)
            }
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 80)
            .onChange(of: activeTab) { _, newTab in
                if !loadedTabs.contains(newTab) {
                    loadedTabs.insert(newTab)
                }
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
            if let tab = notification.object as? TabSelection {
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
        // 8. 로그인 직후: 계정이 비어 있고 기기에 게스트 일정이 있으면 한 번 가져오기를 제안
        .task(id: authManager.accessState.accountUserID) { offerGuestImportIfNeeded() }
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
            if authManager.accessState.accountUserID == nil && !MoraApp.presentationDemoMode {
                loadedTabs.insert(.routine)
                activeTab = .routine
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
    /// 로그인하면 게스트 일정의 알림이 멈추므로, 계정이 비어 있을 때 한 번만 가져오기를 묻습니다.
    /// 이미 일정이 있는 계정이거나 한 번 물어본 계정은 설정의 '기기 일정을 이 계정으로 복사'를 씁니다.
    fileprivate func offerGuestImportIfNeeded() {
        guard let userID = authManager.accessState.accountUserID,
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
        guard let userID = authManager.accessState.accountUserID else { return }
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

// MARK: - Widget Deep Link Notification
extension Notification.Name {
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
