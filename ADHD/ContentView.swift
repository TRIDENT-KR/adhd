import SwiftUI

// MARK: - Custom Bottom Bar
struct CustomBottomBar: View {
    @Binding var activeTab: TabSelection
    @ObservedObject var langManager = LocalizationManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion


    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            TabBarItem(iconName: "square.grid.2x2", label: "Routine", isActive: activeTab == .routine, reduceMotion: reduceMotion) {
                if reduceMotion { activeTab = .routine } else { withAnimation(.spring()) { activeTab = .routine } }
            }
            Spacer()
            TabBarItem(iconName: "mic.fill", label: "Voice", isActive: activeTab == .voice, reduceMotion: reduceMotion) {
                if reduceMotion { activeTab = .voice } else { withAnimation(.spring()) { activeTab = .voice } }
            }
            Spacer()
            TabBarItem(iconName: "calendar", label: "Planner", isActive: activeTab == .planner, reduceMotion: reduceMotion) {
                if reduceMotion { activeTab = .planner } else { withAnimation(.spring()) { activeTab = .planner } }
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
                    .opacity(isActive ? 1 : 0.7)

                // Active Dot Indicator
                Circle()
                    .fill(DesignSystem.Colors.primary)
                    .frame(width: 4, height: 4)
                    .opacity(isActive ? 1 : 0)
                    .offset(y: 2)
            }
            .foregroundColor(
                isActive ? DesignSystem.Colors.primary : DesignSystem.Colors.onSurfaceVariant.opacity(0.5)
            )
            .frame(width: 80, height: 56)
            .contentShape(Rectangle())
            .animation(reduceMotion ? .none : .spring(response: 0.3, dampingFraction: 0.7), value: isActive)
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("\(label) tab")
        .accessibilityHint(isActive ? "Currently selected" : "Double tap to switch to \(label)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
