import SwiftUI

// MARK: - Custom Bottom Bar
struct CustomBottomBar: View {
    @Binding var activeTab: TabSelection
    @ObservedObject var langManager = LocalizationManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 탭 전환. 넘침 없는 곡선(DESIGN.md: 300ms, 0.4/0/0.2/1)을 씁니다.
    /// 화면(페이지)을 넘기는 애니메이션과 연달아 누를 때의 순서는 MainTabView(TabPagerSync)가 맞춥니다.
    private func select(_ tab: TabSelection) {
        guard activeTab != tab else { return }
        if reduceMotion {
            activeTab = tab
        } else {
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.3)) { activeTab = tab }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            TabBarItem(iconName: "square.grid.2x2", label: "Routine", isActive: activeTab == .routine, reduceMotion: reduceMotion) {
                select(.routine)
            }
            TabBarItem(iconName: "mic.fill", label: "Voice", isActive: activeTab == .voice, reduceMotion: reduceMotion) {
                select(.voice)
            }
            TabBarItem(iconName: "calendar", label: "Planner", isActive: activeTab == .planner, reduceMotion: reduceMotion) {
                select(.planner)
            }
        }
        .padding(.vertical, 12)
        .background(DesignSystem.Colors.background)
        .contentShape(Rectangle())
        .padding(.bottom, 20)
        .padding(.horizontal, 16)
    }
}

struct TabBarItem: View {
    let iconName: String
    let label:    String
    let isActive: Bool
    var reduceMotion: Bool = false
    let action:   () -> Void

    var body: some View {
        Button(action: {
            Haptic.impact(.medium)
            action()
        }) {
            VStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.title3.weight(isActive ? .bold : .medium))
                    .scaleEffect(isActive ? 1.15 : 1.0)

                Text(verbatim: label)
                    .font(DesignSystem.Typography.labelSm)
                    .fontWeight(isActive ? .semibold : .regular)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                // Active Dot Indicator
                Circle()
                    .fill(DesignSystem.Colors.primary)
                    .frame(width: 4, height: 4)
                    .opacity(isActive ? 1 : 0)
                    .offset(y: 2)
            }
            .foregroundColor(
                // 비활성 탭도 4.5:1 이상 (예전 0.5×0.7 투명도는 1.8:1이었음)
                isActive ? DesignSystem.Colors.primary : DesignSystem.Colors.onSurfaceMeta
            )
            .frame(maxWidth: .infinity, minHeight: 56)
            .contentShape(Rectangle())
            .animation(reduceMotion ? .none : .spring(response: 0.3, dampingFraction: 0.7), value: isActive)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(L.tabAccessibilityLabel(label))
        .accessibilityHint(isActive ? L.tabAccessibilitySelected : L.tabAccessibilityHint(label))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
