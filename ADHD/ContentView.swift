import SwiftUI

// MARK: - Custom Bottom Bar
struct CustomBottomBar: View {
    @Binding var activeTab: TabSelection

    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            TabBarItem(iconName: "square.grid.2x2", label: L.tabRoutine, isActive: activeTab == .routine) {
                withAnimation(.spring()) { activeTab = .routine }
            }
            Spacer()
            TabBarItem(iconName: "mic.fill", label: L.tabVoice, isActive: activeTab == .voice) {
                withAnimation(.spring()) { activeTab = .voice }
            }
            Spacer()
            TabBarItem(iconName: "calendar", label: L.tabPlanner, isActive: activeTab == .planner) {
                withAnimation(.spring()) { activeTab = .planner }
            }
            Spacer()
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
    let action:   () -> Void

    var body: some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        }) {
            VStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: 26, weight: isActive ? .bold : .medium))
                    .scaleEffect(isActive ? 1.15 : 1.0)

                Text(label)
                    .font(DesignSystem.Typography.labelSm)
                    .fontWeight(isActive ? .semibold : .regular)
                    .opacity(isActive ? 1 : 0.6)

                // Active Dot Indicator
                Circle()
                    .fill(DesignSystem.Colors.primary)
                    .frame(width: 4, height: 4)
                    .opacity(isActive ? 1 : 0)
                    .offset(y: 2)
            }
            .foregroundColor(
                isActive ? DesignSystem.Colors.primary : DesignSystem.Colors.onSurfaceVariant.opacity(0.3)
            )
            .frame(width: 80, height: 56)
            .contentShape(Rectangle())
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isActive)
        }
        .buttonStyle(PlainButtonStyle())
    }
}
