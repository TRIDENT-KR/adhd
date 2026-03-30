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
}

// MARK: - Lock Screen Timeline Provider
struct LockScreenProvider: TimelineProvider {
    func placeholder(in context: Context) -> LockScreenEntry {
        LockScreenEntry(date: .now, pendingCount: 5, nextTaskName: "Morning Workout", routineProgress: 0.6, routineCompleted: 3, routineTotal: 5)
    }

    func getSnapshot(in context: Context, completion: @escaping (LockScreenEntry) -> Void) {
        completion(makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LockScreenEntry>) -> Void) {
        let entry = makeEntry()
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: .now)!
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func makeEntry() -> LockScreenEntry {
        let payload = WidgetDataStore.read()
        let pending = payload?.allPendingTasks ?? []
        let routines = payload?.routines ?? []
        let completed = routines.filter(\.isCompleted).count
        let total = routines.count
        let progress = total > 0 ? Double(completed) / Double(total) : 0

        return LockScreenEntry(
            date: .now,
            pendingCount: pending.count,
            nextTaskName: pending.first?.task,
            routineProgress: progress,
            routineCompleted: completed,
            routineTotal: total
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
        .configurationDisplayName(WidgetL.routineProgress)
        .description("Shows routine completion progress")
        .supportedFamilies([.accessoryCircular])
    }
}

struct RoutineProgressView: View {
    let entry: LockScreenEntry

    var body: some View {
        Gauge(value: entry.routineProgress) {
            // center label
            VStack(spacing: -1) {
                Text("\(entry.routineCompleted)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Text("/\(entry.routineTotal)")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .gaugeStyle(.accessoryCircularCapacity)
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
        .configurationDisplayName(WidgetL.nextTask)
        .description("Shows your next task on the lock screen")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct NextTaskLockView: View {
    let entry: LockScreenEntry

    var body: some View {
        if let taskName = entry.nextTaskName {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "target")
                        .font(.system(size: 9, weight: .bold))
                    Text(WidgetL.nextTask)
                        .font(.system(size: 10, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                }

                Text(taskName)
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(1)

                if entry.pendingCount > 1 {
                    Text("+\(entry.pendingCount - 1) \(WidgetL.moreTasks)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerBackground(for: .widget) { Color.clear }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text(WidgetL.allDone)
                        .font(.system(size: 14, weight: .bold))
                }
                Text(WidgetL.noPendingTasks)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
        .configurationDisplayName(WidgetL.taskCount)
        .description("Shows remaining task count inline")
        .supportedFamilies([.accessoryInline])
    }
}

struct TaskCountInlineView: View {
    let entry: LockScreenEntry

    var body: some View {
        if entry.pendingCount > 0 {
            Label {
                Text("\(entry.pendingCount) \(WidgetL.tasksRemaining)")
            } icon: {
                Image(systemName: "checklist")
            }
            .containerBackground(for: .widget) { Color.clear }
        } else {
            Label {
                Text(WidgetL.allDone)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .containerBackground(for: .widget) { Color.clear }
        }
    }
}
