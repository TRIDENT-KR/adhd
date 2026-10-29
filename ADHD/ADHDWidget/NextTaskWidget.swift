import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Next Task Widget (Small + Medium)
/// 다음 미완료 태스크를 한눈에 보여주는 위젯 (인터랙티브 완료 토글 지원)

struct NextTaskEntry: TimelineEntry {
    let date: Date
    let task: WidgetTaskSnapshot?
    let upcomingTasks: [WidgetTaskSnapshot]
    /// 오늘 할 일이 하나라도 있는지. false면 '모두 완료'가 아니라 '할 일이 없어요'를 보여 줍니다.
    var hasTasks: Bool = true
    let isPreview: Bool

    /// 위젯 갤러리·로딩 중에 보여 줄 예시
    static func sample(date: Date) -> NextTaskEntry {
        let pending = WidgetSample.pending
        return NextTaskEntry(date: date, task: pending.first, upcomingTasks: pending, isPreview: true)
    }
}

struct NextTaskProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextTaskEntry {
        .sample(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (NextTaskEntry) -> Void) {
        // 위젯 갤러리에서는 잠금 화면 대신 예시를 보여 줍니다. Pro이고 오늘 할 일이 있으면 실제 내용을 씁니다.
        guard !context.isPreview || WidgetSample.showsRealData else {
            completion(.sample(date: .now))
            return
        }
        completion(makeEntry(at: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextTaskEntry>) -> Void) {
        let now = Date()
        // 시스템이 갱신을 미뤄도 자정에는 그날 목록으로 바뀌도록 자정 항목을 함께 넣습니다.
        var entries = [makeEntry(at: now)]
        if let midnight = WidgetDataPayload.nextMidnight(after: now) {
            entries.append(makeEntry(at: midnight))
        }
        let nextRefresh = WidgetDataPayload.nextRefreshDate(after: now)
        completion(Timeline(entries: entries, policy: .after(nextRefresh)))
    }

    private func makeEntry(at date: Date) -> NextTaskEntry {
        let payload = WidgetDataStore.read(for: date)
        let pending = payload?.allPendingTasks ?? []
        return NextTaskEntry(
            date: date,
            task: pending.first,
            upcomingTasks: pending,
            hasTasks: payload?.hasTasks ?? false,
            isPreview: false
        )
    }
}

// MARK: - Small Widget View
struct NextTaskSmallView: View {
    let entry: NextTaskEntry
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if let task = entry.task {
            VStack(alignment: .leading, spacing: 6) {
                // 상단: 카테고리 아이콘 + 라벨
                HStack(spacing: 5) {
                    Image(systemName: task.category == "Routine" ? "arrow.trianglehead.2.counterclockwise" : "calendar")
                        .font(WDS.Typography.labelSm)
                        .foregroundStyle(WDS.Colors.primary)
                        .accessibilityHidden(true)

                    Text(WidgetL.nextTask)
                        .font(WDS.Typography.labelSm)
                        .foregroundStyle(WDS.Colors.onSurfaceMeta)

                    Spacer(minLength: 0)
                }

                Spacer(minLength: 0)

                // 중앙: 태스크 이름 (이 위젯의 초점)
                Text(task.task)
                    .font(WDS.Typography.headline)
                    .foregroundStyle(WDS.Colors.onSurfaceVariant)
                    .lineLimit(typeSize > .large ? 2 : 3)
                    .minimumScaleFactor(0.85)

                // 하단: 시간 + 완료 버튼
                HStack(spacing: 4) {
                    if let time = task.displayTime {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.fill")
                                .font(WDS.Typography.caption)
                                .accessibilityHidden(true)
                            Text(time)
                                .font(.footnote.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                        .foregroundStyle(WDS.Colors.primary)
                    }

                    Spacer(minLength: 0)

                    // 인터랙티브 완료 버튼 (누르는 영역 40pt)
                    WidgetCompleteButton(task: task, size: 26, hitSize: 40)
                        .padding(.trailing, -8)
                        .padding(.bottom, -8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .containerBackground(for: .widget) {
                WDS.Colors.background
            }
            .widgetURL(URL(string: "mora://tab/voice"))
        } else {
            NextTaskEmptyView(hasTasks: entry.hasTasks, iconSize: 32)
        }
    }
}

// MARK: - Medium Widget View (Multiple Tasks)
struct NextTaskMediumView: View {
    let entry: NextTaskEntry
    @Environment(\.dynamicTypeSize) private var typeSize

    /// DESIGN.md: 한 화면에 누를 수 있는 항목은 세 개까지
    private var rowLimit: Int { WDS.rowLimit(3, for: typeSize) }

    var body: some View {
        if entry.upcomingTasks.isEmpty {
            NextTaskEmptyView(hasTasks: entry.hasTasks, iconSize: 36)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                // 헤더
                HStack(spacing: 5) {
                    Image(systemName: "target")
                        .font(WDS.Typography.labelSm)
                        .foregroundStyle(WDS.Colors.primary)
                        .accessibilityHidden(true)
                    Text(WidgetL.upNext)
                        .font(WDS.Typography.titleSm)
                        .foregroundStyle(WDS.Colors.onSurfaceVariant)

                    Spacer()

                    Text(WidgetL.remaining(entry.upcomingTasks.count))
                        .font(WDS.Typography.caption)
                        .foregroundStyle(WDS.Colors.onSurfaceMeta)
                }

                // 태스크 목록 (인터랙티브 토글)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(entry.upcomingTasks.prefix(rowLimit)) { task in
                        WidgetTaskRow(task: task, showsCategory: true)
                    }

                    if entry.upcomingTasks.count > rowLimit {
                        Text(WidgetL.more(entry.upcomingTasks.count - rowLimit))
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
            .widgetURL(URL(string: "mora://tab/voice"))
        }
    }
}

// MARK: - Empty State
/// 오늘 할 일을 모두 끝냈을 때와, 아예 없을 때를 구분해 보여 줍니다.
private struct NextTaskEmptyView: View {
    let hasTasks: Bool
    let iconSize: CGFloat

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: hasTasks ? "checkmark.circle.fill" : "sun.max.fill")
                .font(.system(size: iconSize))
                .foregroundStyle(hasTasks ? WDS.Colors.tertiary : WDS.Colors.primary)
                .accessibilityHidden(true)

            Text(hasTasks ? WidgetL.allDone : WidgetL.noTasks)
                .font(WDS.Typography.titleSm)
                .foregroundStyle(WDS.Colors.onSurfaceVariant)
                .multilineTextAlignment(.center)

            if !hasTasks {
                Text(WidgetL.tapToAdd)
                    .font(WDS.Typography.caption)
                    .foregroundStyle(WDS.Colors.primary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .containerBackground(for: .widget) {
            WDS.Colors.background
        }
        .widgetURL(URL(string: "mora://tab/voice"))
    }
}

// MARK: - Adaptive Widget View
struct NextTaskWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: NextTaskEntry

    var body: some View {
        Group {
            if !entry.isPreview, let reason = WidgetDataStore.lockReason {
                WidgetLockedView(family: family, reason: reason)   // D13: 위젯은 Pro 전용
            } else {
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
        .dynamicTypeSize(...WDS.maxTypeSize)
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
        .description(WidgetL.nextTaskDescription)
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Preview Data
/// 위젯 갤러리·로딩 중에 보여 줄 예시 할 일. 앱 언어를 따르고, 실제 할 일과 겹치지 않는 고정 ID를 씁니다.
enum WidgetSample {
    static var routines: [WidgetTaskSnapshot] {
        [
            sample("A0000000-0000-0000-0000-000000000001", WidgetL.sampleWalk, "07:30 AM", "Routine", done: true),
            sample("A0000000-0000-0000-0000-000000000002", WidgetL.sampleMedicine, "09:00 AM", "Routine", done: true),
            sample("A0000000-0000-0000-0000-000000000003", WidgetL.sampleReading, "09:00 PM", "Routine"),
            sample("A0000000-0000-0000-0000-000000000004", WidgetL.sampleWindDown, "10:30 PM", "Routine"),
        ]
    }

    static var appointments: [WidgetTaskSnapshot] {
        [
            sample("A0000000-0000-0000-0000-000000000005", WidgetL.sampleMeeting, "02:00 PM", "Appointment",
                   recurrence: WidgetL.sampleWeekly),
            sample("A0000000-0000-0000-0000-000000000006", WidgetL.sampleDentist, "05:30 PM", "Appointment"),
        ]
    }

    static var pending: [WidgetTaskSnapshot] {
        WidgetDataPayload(accountScope: "", routines: routines, appointments: appointments, updatedAt: .now)
            .allPendingTasks
    }

    /// 갤러리에서도 실제 내용을 보여 줄 수 있는지: Pro이고 오늘 할 일이 있을 때만.
    static var showsRealData: Bool {
        WidgetDataStore.lockReason == nil && WidgetDataStore.read()?.hasTasks == true
    }

    private static func sample(
        _ id: String, _ name: String, _ time: String, _ category: String,
        done: Bool = false, recurrence: String? = nil
    ) -> WidgetTaskSnapshot {
        WidgetTaskSnapshot(
            id: UUID(uuidString: id) ?? UUID(),
            task: name,
            time: time,
            category: category,
            isCompleted: done,
            recurrenceLabel: recurrence
        )
    }
}
