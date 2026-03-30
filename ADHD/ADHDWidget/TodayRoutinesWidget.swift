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
        TodayRoutinesEntry(date: .now, routines: Self.previewRoutines, isPreview: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayRoutinesEntry) -> Void) {
        let routines = WidgetDataStore.read()?.routines ?? Self.previewRoutines
        completion(TodayRoutinesEntry(date: .now, routines: routines, isPreview: context.isPreview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayRoutinesEntry>) -> Void) {
        let routines = WidgetDataStore.read()?.routines ?? []
        let entry = TodayRoutinesEntry(date: .now, routines: routines, isPreview: false)
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: .now)!
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    static let previewRoutines: [WidgetTaskSnapshot] = [
        .init(id: UUID(), task: "Morning Workout", time: "07:00 AM", category: "Routine", isCompleted: true, recurrenceLabel: nil),
        .init(id: UUID(), task: "Take Medicine", time: "08:00 AM", category: "Routine", isCompleted: true, recurrenceLabel: nil),
        .init(id: UUID(), task: "Read 30 min", time: "09:00 PM", category: "Routine", isCompleted: false, recurrenceLabel: nil),
        .init(id: UUID(), task: "Journal", time: "10:00 PM", category: "Routine", isCompleted: false, recurrenceLabel: nil),
    ]
}

// MARK: - Small Widget View (Compact Routine)
struct TodayRoutinesSmallView: View {
    let entry: TodayRoutinesEntry

    private var completed: Int { entry.routines.filter(\.isCompleted).count }
    private var total: Int { entry.routines.count }
    private var progress: Double { total > 0 ? Double(completed) / Double(total) : 0 }

    var body: some View {
        if entry.routines.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "arrow.trianglehead.2.counterclockwise")
                    .font(.system(size: 24))
                    .foregroundStyle(WDS.Colors.onSurfaceVariant.opacity(0.2))
                Text(WidgetL.noTasks)
                    .font(WDS.Typography.caption)
                    .foregroundStyle(WDS.Colors.onSurfaceVariant.opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .containerBackground(for: .widget) { WDS.Colors.background }
            .widgetURL(URL(string: "waitwhat://tab/routine"))
        } else {
            VStack(spacing: 8) {
                // 진행률 링
                ZStack {
                    Circle()
                        .stroke(WDS.Colors.onSurfaceVariant.opacity(0.1), lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(WDS.Colors.tertiary, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))

                    VStack(spacing: 0) {
                        if completed == total && total > 0 {
                            Image(systemName: "checkmark")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(WDS.Colors.tertiary)
                        } else {
                            Text("\(Int(progress * 100))%")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(WDS.Colors.onSurfaceVariant)
                        }
                    }
                }
                .frame(width: 58, height: 58)

                // 카운트
                Text("\(completed)/\(total) \(WidgetL.routines)")
                    .font(WDS.Typography.caption)
                    .foregroundStyle(WDS.Colors.onSurfaceVariant.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .containerBackground(for: .widget) { WDS.Colors.background }
            .widgetURL(URL(string: "waitwhat://tab/routine"))
        }
    }
}

// MARK: - Medium Widget View
struct TodayRoutinesMediumView: View {
    let entry: TodayRoutinesEntry

    private var completed: Int { entry.routines.filter(\.isCompleted).count }
    private var total: Int { entry.routines.count }
    private var progress: Double { total > 0 ? Double(completed) / Double(total) : 0 }

    var body: some View {
        if entry.routines.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 0) {
                // 헤더: 타이틀 + 진행률
                header
                    .padding(.bottom, 8)

                // 루틴 리스트 (최대 4개 + 인터랙티브)
                VStack(spacing: 4) {
                    ForEach(entry.routines.prefix(4)) { routine in
                        routineRow(routine)
                    }

                    if entry.routines.count > 4 {
                        Text("+\(entry.routines.count - 4) \(WidgetL.moreTasks)")
                            .font(WDS.Typography.caption)
                            .foregroundStyle(WDS.Colors.onSurfaceVariant.opacity(0.4))
                            .padding(.leading, 24)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(for: .widget) {
                WDS.Colors.background
            }
            .widgetURL(URL(string: "waitwhat://tab/routine"))
        }
    }

    // MARK: - Header
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(WidgetL.routines)
                    .font(WDS.Typography.titleSm)
                    .foregroundStyle(WDS.Colors.onSurfaceVariant)

                Text("\(completed)/\(total)")
                    .font(WDS.Typography.caption)
                    .foregroundStyle(WDS.Colors.onSurfaceVariant.opacity(0.5))
            }

            Spacer()

            // 원형 진행률
            ZStack {
                Circle()
                    .stroke(WDS.Colors.onSurfaceVariant.opacity(0.1), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(WDS.Colors.tertiary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                if completed == total && total > 0 {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(WDS.Colors.tertiary)
                } else {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(WDS.Colors.onSurfaceVariant)
                }
            }
            .frame(width: 30, height: 30)
        }
    }

    // MARK: - Routine Row (Interactive)
    private func routineRow(_ routine: WidgetTaskSnapshot) -> some View {
        HStack(spacing: 8) {
            // 인터랙티브 완료 토글
            Button(intent: ToggleTaskIntent(taskID: routine.id.uuidString)) {
                Image(systemName: routine.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(routine.isCompleted ? WDS.Colors.tertiary : WDS.Colors.onSurfaceVariant.opacity(0.3))
            }
            .buttonStyle(.plain)

            // 태스크 이름
            Text(routine.task)
                .font(WDS.Typography.bodyMd)
                .foregroundStyle(
                    routine.isCompleted
                        ? WDS.Colors.onSurfaceVariant.opacity(0.35)
                        : WDS.Colors.onSurfaceVariant
                )
                .strikethrough(routine.isCompleted, color: WDS.Colors.onSurfaceVariant.opacity(0.3))
                .lineLimit(1)

            Spacer()

            // 시간
            if let time = routine.time, !time.isEmpty {
                Text(time)
                    .font(WDS.Typography.caption)
                    .foregroundStyle(WDS.Colors.onSurfaceVariant.opacity(0.4))
            }
        }
    }

    // MARK: - Empty State
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.trianglehead.2.counterclockwise")
                .font(.system(size: 28))
                .foregroundStyle(WDS.Colors.onSurfaceVariant.opacity(0.2))

            Text(WidgetL.noTasks)
                .font(WDS.Typography.bodyMd)
                .foregroundStyle(WDS.Colors.onSurfaceVariant.opacity(0.5))

            Text(WidgetL.tapToAdd)
                .font(WDS.Typography.caption)
                .foregroundStyle(WDS.Colors.primary.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(for: .widget) {
            WDS.Colors.background
        }
        .widgetURL(URL(string: "waitwhat://tab/routine"))
    }
}

// MARK: - Adaptive Widget View
struct TodayRoutinesWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: TodayRoutinesEntry

    var body: some View {
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

// MARK: - Widget Configuration
struct TodayRoutinesWidget: Widget {
    let kind = "TodayRoutinesWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TodayRoutinesProvider()) { entry in
            TodayRoutinesWidgetView(entry: entry)
        }
        .configurationDisplayName(WidgetL.routines)
        .description("Track your daily routines at a glance")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
