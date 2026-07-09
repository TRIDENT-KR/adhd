import SwiftUI
import WidgetKit

// MARK: - Widget Locked View
/// D13: 위젯은 Pro 전용 — 무료 사용자에게는 자물쇠 플레이스홀더를 표시하고
/// 탭하면 `mora://paywall` 딥링크로 앱 내 페이월을 연다.
struct WidgetLockedView: View {
    let family: WidgetFamily

    var body: some View {
        content
            .widgetURL(URL(string: "mora://paywall"))
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemSmall:
            VStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(WDS.Colors.primary)
                Text("Mora Pro")
                    .font(WDS.Typography.titleSm)
                    .foregroundStyle(WDS.Colors.onSurfaceVariant)
                Text(WidgetL.proCTA)
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
                    Text("Mora Pro")
                        .font(WDS.Typography.titleSm)
                        .foregroundStyle(WDS.Colors.onSurfaceVariant)
                    Text(WidgetL.proLocked)
                        .font(WDS.Typography.bodyMd)
                        .foregroundStyle(WDS.Colors.onSurfaceVariant.opacity(0.7))
                    Text(WidgetL.proCTA)
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
                    Text("Mora Pro")
                        .font(.system(size: 12, weight: .bold))
                }
                Text(WidgetL.proCTA)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerBackground(for: .widget) { Color.clear }

        default: // .accessoryInline 등
            Label("Mora Pro", systemImage: "lock.fill")
                .containerBackground(for: .widget) { Color.clear }
        }
    }
}
