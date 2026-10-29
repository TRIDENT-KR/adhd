import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Today's Routines Widget (Medium + Small)
/// 오늘의 루틴 목록과 진행 상황을 보여주는 위젯 (인터랙티브 완료 토글 지원)

struct TodayRoutinesEntry: TimelineEntry {
    let date: Date
    let routines: [WidgetTaskSnapshot]
    let isPreview: Bool
}

struct TodayRoutinesProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayRoutinesEntry {
        TodayRoutinesEntry(date: .now, routines: WidgetSample.routines, isPreview: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayRoutinesEntry) -> Void) {
        // 위젯 갤러리에서는 잠금 화면 대신 예시를 보여 줍니다. Pro이고 오늘 할 일이 있으면 실제 내용을 씁니다.
        guard !context.isPreview || WidgetSample.showsRealData else {
            completion(placeholder(in: context))
            return
        }
        completion(makeEntry(at: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayRoutinesEntry>) -> Void) {
        let now = Date()
        // 시스템이 갱신을 미뤄도 자정에는 그날 목록으로 바뀌도록 자정 항목을 함께 넣습니다.
        var entries = [makeEntry(at: now)]
        if let midnight = WidgetDataPayload.nextMidnight(after: now) {
            entries.append(makeEntry(at: midnight))
        }
        let nextRefresh = WidgetDataPayload.nextRefreshDate(after: now)
        completion(Timeline(entries: entries, policy: .after(nextRefresh)))
    }

    private func makeEntry(at date: Date) -> TodayRoutinesEntry {
        TodayRoutinesEntry(date: date, routines: WidgetDataStore.read(for: date)?.routines ?? [], isPreview: false)
    }
}

// MARK: - Small Widget View (Compact Routine)
struct TodayRoutinesSmallView: View {
    let entry: TodayRoutinesEntry

    private var completed: Int { entry.routines.filter(\.isCompleted).count }
    private var total: Int { entry.routines.count }
    private var progress: Double { total > 0 ? Double(completed) / Double(total) : 0 }

    var body: some View {
        if entry.routines.isEmpty {
            TodayRoutinesEmptyView()
        } else {
            VStack(spacing: 10) {
                // 진행률 링 (이 위젯의 초점)
                ZStack {
                    Circle()
                        .stroke(WDS.Colors.onSurfaceVariant.opacity(0.1), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(WDS.Colors.tertiary, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))

                    if completed == total && total > 0 {
                        Image(systemName: "checkmark")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(WDS.Colors.tertiary)
                    } else {
                        Text("\(Int(progress * 100))%")
                            .font(.system(.headline, design: .rounded).weight(.bold))
                            .foregroundStyle(WDS.Colors.onSurfaceVariant)
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                    }
                }
                .frame(width: 70, height: 70)
                .accessibilityHidden(true)

                // 카운트
                Text("\(completed)/\(total) \(WidgetL.routines)")
                    .font(WDS.Typography.labelSm)
                    .foregroundStyle(WDS.Colors.onSurfaceMeta)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .containerBackground(for: .widget) { WDS.Colors.background }
            .widgetURL(URL(string: "mora://tab/routine"))
        }
    }
}

// MARK: - Medium Widget View
struct TodayRoutinesMediumView: View {
    let entry: TodayRoutinesEntry
    @Environment(\.dynamicTypeSize) private var typeSize

    private var completed: Int { entry.routines.filter(\.isCompleted).count }
    private var total: Int { entry.routines.count }
    private var progress: Double { total > 0 ? Double(completed) / Double(total) : 0 }
    /// DESIGN.md: 한 화면에 누를 수 있는 항목은 세 개까지
    private var rowLimit: Int { WDS.rowLimit(3, for: typeSize) }

    var body: some View {
        if entry.routines.isEmpty {
            TodayRoutinesEmptyView()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                // 헤더: 타이틀 + 진행률
                header

                // 루틴 리스트 (인터랙티브)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(entry.routines.prefix(rowLimit)) { routine in
                        WidgetTaskRow(task: routine)
                    }

                    if entry.routines.count > rowLimit {
                        Text(WidgetL.more(entry.routines.count - rowLimit))
                            .font(WDS.Typography.caption)
                            .foregroundStyle(WDS.Colors.onSurfaceMeta)
                            .padding(.leading, 34)
                    }
                }
                .padding(.leading, -5)   // 넓힌 누름 영역만큼 체크 원을 제목 줄에 맞춥니다
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(for: .widget) {
                WDS.Colors.background
            }
            .widgetURL(URL(string: "mora://tab/routine"))
        }
    }

    // MARK: - Header
    private var header: some View {
        HStack(spacing: 6) {
            Text(WidgetL.routines)
                .font(WDS.Typography.titleSm)
                .foregroundStyle(WDS.Colors.onSurfaceVariant)

            Spacer()

            Text("\(completed)/\(total)")
                .font(WDS.Typography.labelSm)
                .foregroundStyle(WDS.Colors.onSurfaceMeta)

            // 원형 진행률 (글자는 옆 숫자로 읽습니다)
            ZStack {
                Circle()
                    .stroke(WDS.Colors.onSurfaceVariant.opacity(0.1), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(WDS.Colors.tertiary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                if completed == total && total > 0 {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(WDS.Colors.tertiary)
                }
            }
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Empty State
private struct TodayRoutinesEmptyView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.trianglehead.2.counterclockwise")
                .font(.system(size: 28))
                .foregroundStyle(WDS.Colors.primary)
                .accessibilityHidden(true)

            Text(WidgetL.noRoutines)
                .font(WDS.Typography.titleSm)
                .foregroundStyle(WDS.Colors.onSurfaceVariant)
                .multilineTextAlignment(.center)

            Text(WidgetL.tapToAdd)
                .font(WDS.Typography.caption)
                .foregroundStyle(WDS.Colors.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .containerBackground(for: .widget) {
            WDS.Colors.background
        }
        .widgetURL(URL(string: "mora://tab/routine"))
    }
}

// MARK: - Adaptive Widget View
struct TodayRoutinesWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: TodayRoutinesEntry

    var body: some View {
        Group {
            if !entry.isPreview, let reason = WidgetDataStore.lockReason {
                WidgetLockedView(family: family, reason: reason)   // D13: 위젯은 Pro 전용
            } else {
                switch family {
                case .systemSmall:
                    TodayRoutinesSmallView(entry: entry)
                case .systemMedium:
                    TodayRoutinesMediumView(entry: entry)
                default:
                    TodayRoutinesMediumView(entry: entry)
                }
            }
        }
        .dynamicTypeSize(...WDS.maxTypeSize)
    }
}

// MARK: - Widget Configuration
struct TodayRoutinesWidget: Widget {
    let kind = "TodayRoutinesWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TodayRoutinesProvider()) { entry in
            TodayRoutinesWidgetView(entry: entry)
        }
        .configurationDisplayName(WidgetL.routines)
        .description(WidgetL.routinesDescription)
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
