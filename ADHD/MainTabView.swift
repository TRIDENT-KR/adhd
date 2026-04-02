import SwiftUI

struct MainTabView: View {
    @State var activeTab: TabSelection = .voice
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @EnvironmentObject private var taskManager: TaskManager
    @StateObject private var alarmManager = AlarmManager.shared
    @ObservedObject private var langManager = LocalizationManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 한 번이라도 방문한 탭을 추적하여 지연 로딩
    @State private var loadedTabs: Set<TabSelection> = [.voice]
    /// HomeVoiceInterfaceView에서 모달이 열려 있는지 여부 
    @State private var isVoiceModalVisible = false

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

                HomeVoiceInterfaceView(isModalVisible: $isVoiceModalVisible)
                    .tag(TabSelection.voice)

                Group {
                    if loadedTabs.contains(.planner) {
                        PlannerView(activeTab: $activeTab)
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
                .accessibilityElement(children: .contain)
                .accessibilityLabel(L.voice.a11yTabBar)
                .blur(radius: isVoiceModalVisible ? 12 : 0)
                .opacity(isVoiceModalVisible ? 0.6 : 1)
                .animation(reduceMotion ? .none : .spring(response: 0.4, dampingFraction: 0.7), value: isVoiceModalVisible)
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
        .onReceive(NotificationCenter.default.publisher(for: .widgetDeepLink)) { notification in
            if let tab = notification.object as? TabSelection {
                if !loadedTabs.contains(tab) {
                    loadedTabs.insert(tab)
                }
                withAnimation { activeTab = tab }
            }
        }
        // 6. 강한 알림 오버레이
        .fullScreenCover(item: $alarmManager.activeAlarm) { alarm in
            AlarmOverlayView(alarm: alarm)
                .interactiveDismissDisabled(true)
        }
    }
}

// MARK: - Widget Deep Link Notification
extension Notification.Name {
    static let widgetDeepLink = Notification.Name("widgetDeepLink")
}

// MARK: - Undo Snackbar
struct UndoSnackbar: View {
    let message: String
    let onUndo: () -> Void

    private static let backgroundColor = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(r: 0x30, g: 0x30, b: 0x30)
            : UIColor(r: 0x3A, g: 0x3A, b: 0x3A)
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
            .accessibilityHint("Double tap to undo the last action")
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
            // Task 2: 영어 문구로 교체 (DesignSystem.Strings.offlineAlertText)
            Text(DesignSystem.Strings.offlineAlertText)
                .font(DesignSystem.Typography.labelSm)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DesignSystem.Colors.onSurfaceVariant.opacity(0.92))
        )
        .padding(.horizontal, 24)
        .padding(.top, 56) // 노치/Dynamic Island 회피
        .accessibilityElement(children: .combine)
        .accessibilityLabel(DesignSystem.Strings.offlineAlertText)
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
        .foregroundColor(.white)
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
