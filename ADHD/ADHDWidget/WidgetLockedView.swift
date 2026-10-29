import SwiftUI
import WidgetKit

// MARK: - Widget Locked View
/// 위젯 데이터를 표시할 수 없을 때, 왜 그런지 한 문장으로 보여줍니다 (Pro 아님·로그인 안 함·앱을 한 번 열어야 함).
/// 탭하면 일반 앱 화면을 열며, 위젯에서 구매를 유도하는 버튼은 두지 않습니다.
struct WidgetLockedView: View {
    let family: WidgetFamily
    let reason: WidgetLockReason

    private var message: String { WidgetL.lockMessage(reason) }

    var body: some View {
        content
            .dynamicTypeSize(...WDS.maxTypeSize)
            .widgetURL(URL(string: "mora://tab/routine"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Mora. \(message)")
            .accessibilityHint(WidgetL.openApp)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemSmall, .systemMedium, .systemLarge:
            // 초점은 이유 한 문장 하나
            VStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(family == .systemSmall ? .title3 : .title2)
                    .foregroundStyle(WDS.Colors.primary)
                Text(message)
                    .font(WDS.Typography.titleSm)
                    .foregroundStyle(WDS.Colors.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .containerBackground(for: .widget) { WDS.Colors.background }

        case .accessoryCircular:
            ZStack {
                Circle()
                    .stroke(.secondary.opacity(0.3), lineWidth: 3)
                Image(systemName: "lock.fill")
                    .font(.title3)
            }
            .containerBackground(for: .widget) { Color.clear }

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label("Mora", systemImage: "lock.fill")
                    .font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerBackground(for: .widget) { Color.clear }

        default: // .accessoryInline 등
            Label("Mora", systemImage: "lock.fill")
                .containerBackground(for: .widget) { Color.clear }
        }
    }
}
