import WidgetKit
import SwiftUI

// MARK: - Lock Screen Widget Entry
struct LockScreenEntry: TimelineEntry {
    let date: Date
    let pendingCount: Int
    let nextTaskName: String?
    let routineProgress: Double
    let routineCompleted: Int
    let routineTotal: Int
    /// 오늘 할 일이 하나라도 있는지. false면 '모두 완료' 대신 '할 일이 없어요'를 보여 줍니다.
    var hasTasks: Bool = true
    var isPreview: Bool = false
}

// MARK: - Lock Screen Timeline Provider
struct LockScreenProvider: TimelineProvider {
    func placeholder(in context: Context) -> LockScreenEntry {
        LockScreenEntry(
            date: .now, pendingCount: WidgetSample.pending.count, nextTaskName: WidgetSample.pending.first?.task,
            routineProgress: 0.5, routineCompleted: 2, routineTotal: 4, isPreview: true
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (LockScreenEntry) -> Void) {
        // 위젯 갤러리에서는 잠금 화면 대신 예시를 보여 줍니다. Pro이고 오늘 할 일이 있으면 실제 내용을 씁니다.
        guard !context.isPreview || WidgetSample.showsRealData else {
            completion(placeholder(in: context))
            return
        }
        completion(makeEntry(at: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LockScreenEntry>) -> Void) {
        let now = Date()
        // 시스템이 갱신을 미뤄도 자정에는 그날 목록으로 바뀌도록 자정 항목을 함께 넣습니다.
        var entries = [makeEntry(at: now)]
        if let midnight = WidgetDataPayload.nextMidnight(after: now) {
            entries.append(makeEntry(at: midnight))
        }
        let nextRefresh = WidgetDataPayload.nextRefreshDate(after: now)
        completion(Timeline(entries: entries, policy: .after(nextRefresh)))
    }

    private func makeEntry(at date: Date) -> LockScreenEntry {
        let payload = WidgetDataStore.read(for: date)
        let pending = payload?.allPendingTasks ?? []
        let routines = payload?.routines ?? []
        let completed = routines.filter(\.isCompleted).count
        let total = routines.count
        let progress = total > 0 ? Double(completed) / Double(total) : 0

        return LockScreenEntry(
            date: date,
            pendingCount: pending.count,
            nextTaskName: pending.first?.task,
            routineProgress: progress,
            routineCompleted: completed,
            routineTotal: total,
            hasTasks: payload?.hasTasks ?? false
        )
    }
}

// MARK: - Circular Lock Screen Widget (Progress Ring)
struct RoutineProgressWidget: Widget {
    let kind = "RoutineProgressWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LockScreenProvider()) { entry in
            RoutineProgressView(entry: entry)
        }
        .configurationDisplayName("Routine Progress")
        .description("See how today's routines are going.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct RoutineProgressView: View {
    let entry: LockScreenEntry

    var body: some View {
        if !entry.isPreview, let reason = WidgetDataStore.lockReason {
            WidgetLockedView(family: .accessoryCircular, reason: reason)   // D13
        } else {
            unlockedContent
        }
    }

    private var unlockedContent: some View {
        Gauge(value: entry.routineProgress) {
            // center label
            VStack(spacing: -1) {
                Text("\(entry.routineCompleted)")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                Text("/\(entry.routineTotal)")
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .minimumScaleFactor(0.7)
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .dynamicTypeSize(...DynamicTypeSize.large)   // 원 안은 공간이 정해져 있어 기본 크기까지만 키웁니다
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WidgetL.routineProgress)
        .accessibilityValue("\(entry.routineCompleted)/\(entry.routineTotal)")
        .containerBackground(for: .widget) { Color.clear }
    }
}

// MARK: - Rectangular Lock Screen Widget (Next Task)
struct NextTaskLockWidget: Widget {
    let kind = "NextTaskLockWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LockScreenProvider()) { entry in
            NextTaskLockView(entry: entry)
        }
        .configurationDisplayName("Next Task")
        .description("Your next task on the Lock Screen.")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct NextTaskLockView: View {
    let entry: LockScreenEntry
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if !entry.isPreview, let reason = WidgetDataStore.lockReason {
                WidgetLockedView(family: .accessoryRectangular, reason: reason)   // D13
            } else {
                unlockedContent
            }
        }
        .dynamicTypeSize(...WDS.maxTypeSize)
    }

    @ViewBuilder
    private var unlockedContent: some View {
        if let taskName = entry.nextTaskName {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: "target")
                        .accessibilityHidden(true)
                    Text(WidgetL.nextTask)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                Text(taskName)
                    .font(.headline)
                    .lineLimit(typeSize > .large ? 1 : 2)
                    .minimumScaleFactor(0.85)

                // 글자를 키우면 이름이 먼저 보이도록 남은 개수 줄은 뺍니다.
                if entry.pendingCount > 1, typeSize <= .large {
                    Text(WidgetL.more(entry.pendingCount - 1))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .containerBackground(for: .widget) { Color.clear }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Label(entry.hasTasks ? WidgetL.allDone : WidgetL.noTasks,
                      systemImage: entry.hasTasks ? "checkmark.circle.fill" : "sun.max.fill")
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                if entry.hasTasks {
                    Text(WidgetL.noPendingTasks)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .containerBackground(for: .widget) { Color.clear }
        }
    }
}

// MARK: - Inline Lock Screen Widget (Task Count)
struct TaskCountInlineWidget: Widget {
    let kind = "TaskCountInlineWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LockScreenProvider()) { entry in
            TaskCountInlineView(entry: entry)
        }
        .configurationDisplayName("Tasks Left")
        .description("How many tasks are left today.")
        .supportedFamilies([.accessoryInline])
    }
}

struct TaskCountInlineView: View {
    let entry: LockScreenEntry

    var body: some View {
        if !entry.isPreview, let reason = WidgetDataStore.lockReason {
            WidgetLockedView(family: .accessoryInline, reason: reason)   // D13
        } else {
            unlockedContent
        }
    }

    @ViewBuilder
    private var unlockedContent: some View {
        if entry.pendingCount > 0 {
            Label {
                Text(WidgetL.remaining(entry.pendingCount))
            } icon: {
                Image(systemName: "checklist")
            }
            .containerBackground(for: .widget) { Color.clear }
        } else {
            Label {
                Text(entry.hasTasks ? WidgetL.allDone : WidgetL.noTasks)
            } icon: {
                Image(systemName: entry.hasTasks ? "checkmark.circle.fill" : "sun.max.fill")
            }
            .containerBackground(for: .widget) { Color.clear }
        }
    }
}
