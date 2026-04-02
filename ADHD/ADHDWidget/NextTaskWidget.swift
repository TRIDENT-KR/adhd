import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Next Task Widget (Small + Medium)
/// 다음 미완료 태스크를 한눈에 보여주는 위젯 (인터랙티브 완료 토글 지원)

struct NextTaskEntry: TimelineEntry {
    let date: Date
    let task: WidgetTaskSnapshot?
    let upcomingTasks: [WidgetTaskSnapshot]
    let isPreview: Bool
}

struct NextTaskProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextTaskEntry {
        NextTaskEntry(date: .now, task: .preview, upcomingTasks: [.preview], isPreview: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (NextTaskEntry) -> Void) {
        let payload = WidgetDataStore.read()
        let pending = payload?.allPendingTasks ?? [.preview]
        completion(NextTaskEntry(
            date: .now,
            task: pending.first ?? .preview,
            upcomingTasks: pending,
            isPreview: context.isPreview
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextTaskEntry>) -> Void) {
        let payload = WidgetDataStore.read()
        let pending = payload?.allPendingTasks ?? []

        let entry = NextTaskEntry(
            date: .now,
            task: pending.first,
            upcomingTasks: pending,
            isPreview: false
        )
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: .now)!
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

// MARK: - Small Widget View
struct NextTaskSmallView: View {
    let entry: NextTaskEntry

    var body: some View {
        if let task = entry.task {
            VStack(alignment: .leading, spacing: 8) {
                // 상단: 카테고리 아이콘 + 라벨
                HStack(spacing: 5) {
                    Image(systemName: task.category == "Routine" ? "arrow.trianglehead.2.counterclockwise" : "calendar")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(WDS.Colors.primary)

                    Text(WidgetL.nextTask)
                        .font(WDS.Typography.caption)
                        .foregroundStyle(WDS.Colors.onSurfaceVariant.opacity(0.6))

                    Spacer()
                }

                Spacer()

                // 중앙: 태스크 이름
                Text(task.task)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(WDS.Colors.onSurfaceVariant)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)

                // 하단: 시간 + 완료 버튼
                HStack {
                    if let time = task.time, !time.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.fill")
                                .font(.system(size: 10))
                            Text(time)
                                .font(WDS.Typography.bodyMd)
                        }
                        .foregroundStyle(WDS.Colors.primary)
                    }

                    Spacer()

                    // 인터랙티브 완료 버튼
                    Button(intent: ToggleTaskIntent(taskID: task.id.uuidString)) {
                        Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22))
                            .foregroundStyle(task.isCompleted ? WDS.Colors.tertiary : WDS.Colors.onSurfaceVariant.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .containerBackground(for: .widget) {
                WDS.Colors.background
            }
            .widgetURL(URL(string: "mora://tab/voice"))
        } else {
            // 모든 태스크 완료
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(WDS.Colors.tertiary)

                Text(WidgetL.allDone)
                    .font(WDS.Typography.titleSm)
                    .foregroundStyle(WDS.Colors.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .containerBackground(for: .widget) {
                WDS.Colors.background
            }
            .widgetURL(URL(string: "mora://tab/voice"))
        }
    }
}

// MARK: - Medium Widget View (Multiple Tasks)
struct NextTaskMediumView: View {
    let entry: NextTaskEntry

    var body: some View {
        if entry.upcomingTasks.isEmpty {
            // 태스크 없음
            HStack(spacing: 16) {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(WDS.Colors.tertiary)
                    Text(WidgetL.allDone)
                        .font(WDS.Typography.titleSm)
                        .foregroundStyle(WDS.Colors.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(14)
            .containerBackground(for: .widget) {
                WDS.Colors.background
            }
            .widgetURL(URL(string: "mora://tab/voice"))
        } else {
            VStack(alignment: .leading, spacing: 0) {
                // 헤더
                HStack(spacing: 5) {
                    Image(systemName: "target")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(WDS.Colors.primary)
                    Text(WidgetL.upNext)
                        .font(WDS.Typography.titleSm)
                        .foregroundStyle(WDS.Colors.onSurfaceVariant)

                    Spacer()

                    Text("\(entry.upcomingTasks.count) \(WidgetL.tasksRemaining)")
                        .font(WDS.Typography.caption)
                        .foregroundStyle(WDS.Colors.onSurfaceVariant.opacity(0.5))
                }
                .padding(.bottom, 8)

                // 태스크 목록 (최대 3개 + 인터랙티브 토글)
                VStack(spacing: 5) {
                    ForEach(entry.upcomingTasks.prefix(3)) { task in
                        HStack(spacing: 8) {
                            // 인터랙티브 완료 버튼
                            Button(intent: ToggleTaskIntent(taskID: task.id.uuidString)) {
                                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 16))
                                    .foregroundStyle(task.isCompleted ? WDS.Colors.tertiary : WDS.Colors.onSurfaceVariant.opacity(0.3))
                            }
                            .buttonStyle(.plain)

                            Text(task.task)
                                .font(WDS.Typography.bodyMd)
                                .foregroundStyle(
                                    task.isCompleted
                                        ? WDS.Colors.onSurfaceVariant.opacity(0.35)
                                        : WDS.Colors.onSurfaceVariant
                                )
                                .strikethrough(task.isCompleted, color: WDS.Colors.onSurfaceVariant.opacity(0.3))
                                .lineLimit(1)

                            Spacer()

                            // 카테고리 아이콘
                            Image(systemName: task.category == "Routine" ? "arrow.trianglehead.2.counterclockwise" : "calendar")
                                .font(.system(size: 9))
                                .foregroundStyle(WDS.Colors.onSurfaceVariant.opacity(0.3))

                            if let time = task.time, !time.isEmpty {
                                Text(time)
                                    .font(WDS.Typography.caption)
                                    .foregroundStyle(WDS.Colors.onSurfaceVariant.opacity(0.4))
                            }
                        }
                    }

                    if entry.upcomingTasks.count > 3 {
                        Text("+\(entry.upcomingTasks.count - 3) \(WidgetL.moreTasks)")
                            .font(WDS.Typography.caption)
                            .foregroundStyle(WDS.Colors.onSurfaceVariant.opacity(0.4))
                            .padding(.leading, 24)
                            .padding(.top, 2)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(for: .widget) {
                WDS.Colors.background
            }
            .widgetURL(URL(string: "mora://tab/voice"))
        }
    }
}

// MARK: - Adaptive Widget View
struct NextTaskWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: NextTaskEntry

    var body: some View {
        switch family {
        case .systemSmall:
            NextTaskSmallView(entry: entry)
        case .systemMedium:
            NextTaskMediumView(entry: entry)
        default:
            NextTaskSmallView(entry: entry)
        }
    }
}

// MARK: - Widget Configuration
struct NextTaskWidget: Widget {
    let kind = "NextTaskWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NextTaskProvider()) { entry in
            NextTaskWidgetView(entry: entry)
        }
        .configurationDisplayName(WidgetL.nextTask)
        .description("Shows your next upcoming tasks")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Preview Data
extension WidgetTaskSnapshot {
    static let preview = WidgetTaskSnapshot(
        id: UUID(),
        task: "Morning Workout",
        time: "07:00 AM",
        category: "Routine",
        isCompleted: false,
        recurrenceLabel: nil
    )
}
