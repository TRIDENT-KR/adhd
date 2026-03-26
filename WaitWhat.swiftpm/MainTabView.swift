import SwiftUI

struct MainTabView: View {
    @State private var activeTab: TabSelection = .planner
    @EnvironmentObject private var networkMonitor: NetworkMonitor

    var body: some View {
        ZStack(alignment: .bottom) {
            // 1. 배경
            DesignSystem.Colors.background.ignoresSafeArea()

            // 2. 현재 탭 뷰
            Group {
                switch activeTab {
                case .routine:
                    RoutineView()
                case .voice:
                    HomeVoiceInterfaceView()
                case .planner:
                    PlannerView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 3. 글로벌 바텀 바
            CustomBottomBar(activeTab: $activeTab)
        }
        // 4. 오프라인 배너 (최상단, ZStack과 별개 오버레이)
        .overlay(alignment: .top) {
            if !networkMonitor.isConnected {
                OfflineBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: networkMonitor.isConnected)
    }
}

// MARK: - Offline Banner
private struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 14, weight: .semibold))
            Text("오프라인 상태입니다. 음성 인식은 제한되지만 로컬 데이터는 안전합니다.")
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
    }
}

// MARK: - Preview
struct MainTabView_Previews: PreviewProvider {
    static var previews: some View {
        MainTabView()
            .environmentObject(NetworkMonitor.shared)
    }
}
