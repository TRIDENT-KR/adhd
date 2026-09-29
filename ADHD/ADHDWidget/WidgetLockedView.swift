import SwiftUI
import WidgetKit

// MARK: - Widget Locked View
/// 위젯 데이터를 표시할 수 없을 때 중립 상태를 보여줍니다.
/// 탭하면 일반 앱 화면을 열며, 위젯에서 구독을 광고하거나 구매를 유도하지 않습니다.
struct WidgetLockedView: View {
    let family: WidgetFamily

    var body: some View {
        content
            .widgetURL(URL(string: "mora://tab/routine"))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Mora. \(WidgetL.unavailable)")
            .accessibilityHint(WidgetL.openApp)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemSmall:
            VStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(WDS.Colors.primary)
                Text("Mora")
                    .font(WDS.Typography.titleSm)
                    .foregroundStyle(WDS.Colors.onSurfaceVariant)
                Text(WidgetL.openApp)
                    .font(WDS.Typography.caption)
                    .foregroundStyle(WDS.Colors.onSurfaceVariant.opacity(0.5))
            }
            .containerBackground(for: .widget) { WDS.Colors.background }

        case .systemMedium, .systemLarge:
            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(WDS.Colors.primary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mora")
                        .font(WDS.Typography.titleSm)
                        .foregroundStyle(WDS.Colors.onSurfaceVariant)
                    Text(WidgetL.unavailable)
                        .font(WDS.Typography.bodyMd)
                        .foregroundStyle(WDS.Colors.onSurfaceVariant.opacity(0.7))
                    Text(WidgetL.openApp)
                        .font(WDS.Typography.caption)
                        .foregroundStyle(WDS.Colors.primary.opacity(0.8))
                }
            }
            .containerBackground(for: .widget) { WDS.Colors.background }

        case .accessoryCircular:
            ZStack {
                Circle()
                    .stroke(.secondary.opacity(0.3), lineWidth: 3)
                Image(systemName: "lock.fill")
                    .font(.system(size: 16))
            }
            .containerBackground(for: .widget) { Color.clear }

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                    Text("Mora")
                        .font(.system(size: 12, weight: .bold))
                }
                Text(WidgetL.openApp)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerBackground(for: .widget) { Color.clear }

        default: // .accessoryInline 등
            Label("Mora", systemImage: "lock.fill")
                .containerBackground(for: .widget) { Color.clear }
        }
    }
}
