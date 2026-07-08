import WidgetKit
import SwiftUI
import ActivityKit
import AlarmKit

// MARK: - Alarm Live Activity
/// AlarmKit 시스템 알람의 잠금화면/Dynamic Island 표시.
/// 알람이 울리는 순간(alert)의 풀스크린 UI는 시스템이 그리고,
/// 스누즈 카운트다운(countdown)·일시정지(paused) 상태를 이 뷰가 렌더링합니다.
struct AlarmLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<MoraAlarmMetadata>.self) { context in
            // ── 잠금화면 / 배너 ──
            HStack(spacing: 12) {
                Image(systemName: "alarm.fill")
                    .font(.title3)
                    .foregroundStyle(WDS.Colors.primary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(taskName(context))
                        .font(WDS.Typography.titleSm)
                        .foregroundStyle(WDS.Colors.onSurfaceVariant)
                        .lineLimit(1)

                    modeLine(context.state.mode)
                        .font(WDS.Typography.bodyMd)
                        .foregroundStyle(WDS.Colors.primary)
                }

                Spacer()
            }
            .padding(16)
            .activityBackgroundTint(WDS.Colors.background)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "alarm.fill")
                        .font(.title3)
                        .foregroundStyle(WDS.Colors.primaryFixedDim)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(taskName(context))
                        .font(WDS.Typography.titleSm)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    modeLine(context.state.mode)
                        .font(WDS.Typography.bodyMd)
                        .foregroundStyle(WDS.Colors.primaryFixedDim)
                }
            } compactLeading: {
                Image(systemName: "alarm.fill")
                    .foregroundStyle(WDS.Colors.primaryFixedDim)
            } compactTrailing: {
                compactTrailingView(context.state.mode)
            } minimal: {
                Image(systemName: "alarm.fill")
                    .foregroundStyle(WDS.Colors.primaryFixedDim)
            }
        }
    }

    // MARK: - Helpers

    private func taskName(_ context: ActivityViewContext<AlarmAttributes<MoraAlarmMetadata>>) -> String {
        context.attributes.metadata?.taskName ?? "Mora"
    }

    /// 상태별 보조 라인: 카운트다운(스누즈 남은 시간) / 일시정지 / 울리는 중
    @ViewBuilder
    private func modeLine(_ mode: AlarmPresentationState.Mode) -> some View {
        switch mode {
        case .countdown(let countdown):
            HStack(spacing: 4) {
                Text(WidgetL.alarmSnoozed)
                Text(timerInterval: Date.now...max(countdown.fireDate, Date.now), countsDown: true)
                    .monospacedDigit()
            }
        case .paused:
            Text(WidgetL.alarmPaused)
        case .alert:
            Text(WidgetL.alarmNow)
        @unknown default:
            Text(WidgetL.alarmNow)
        }
    }

    @ViewBuilder
    private func compactTrailingView(_ mode: AlarmPresentationState.Mode) -> some View {
        switch mode {
        case .countdown(let countdown):
            Text(timerInterval: Date.now...max(countdown.fireDate, Date.now), countsDown: true)
                .monospacedDigit()
                .font(.caption2)
                .frame(maxWidth: 44)
                .foregroundStyle(WDS.Colors.primaryFixedDim)
        default:
            Image(systemName: "bell.fill")
                .foregroundStyle(WDS.Colors.primaryFixedDim)
        }
    }
}
