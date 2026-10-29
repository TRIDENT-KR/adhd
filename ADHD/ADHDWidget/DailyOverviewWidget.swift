import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Daily Overview Widget (Large)
/// 루틴 + 일정을 한눈에 보여주는 대형 위젯 (인터랙티브 완료 토글 + 더 많은 항목 표시)

struct DailyOverviewEntry: TimelineEntry {
    let date: Date
    let routines: [WidgetTaskSnapshot]
    let appointments: [WidgetTaskSnapshot]
    let isPreview: Bool
}

struct DailyOverviewProvider: TimelineProvider {
    func placeholder(in context: Context) -> DailyOverviewEntry {
        DailyOverviewEntry(
            date: .now,
            routines: WidgetSample.routines,
            appointments: WidgetSample.appointments,
            isPreview: true
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (DailyOverviewEntry) -> Void) {
        // 위젯 갤러리에서는 잠금 화면 대신 예시를 보여 줍니다. Pro이고 오늘 할 일이 있으면 실제 내용을 씁니다.
        guard !context.isPreview || WidgetSample.showsRealData else {
            completion(placeholder(in: context))
            return
        }
        completion(makeEntry(at: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DailyOverviewEntry>) -> Void) {
        let now = Date()
        // 시스템이 갱신을 미뤄도 자정에는 날짜와 목록이 바뀌도록 자정 항목을 함께 넣습니다.
        var entries = [makeEntry(at: now)]
        if let midnight = WidgetDataPayload.nextMidnight(after: now) {
            entries.append(makeEntry(at: midnight))
        }
        let nextRefresh = WidgetDataPayload.nextRefreshDate(after: now)
        completion(Timeline(entries: entries, policy: .after(nextRefresh)))
    }

    private func makeEntry(at date: Date) -> DailyOverviewEntry {
        let payload = WidgetDataStore.read(for: date)
        return DailyOverviewEntry(
            date: date,
            routines: payload?.routines ?? [],
            appointments: payload?.appointments ?? [],
            isPreview: false
        )
    }
}

// MARK: - Large Widget View
struct DailyOverviewWidgetView: View {
    let entry: DailyOverviewEntry
    @Environment(\.dynamicTypeSize) private var typeSize

    private var routineCompleted: Int { entry.routines.filter(\.isCompleted).count }
    private var routineTotal: Int { entry.routines.count }
    private var routineProgress: Double { routineTotal > 0 ? Double(routineCompleted) / Double(routineTotal) : 0 }

    // 동적으로 표시 개수 조절: 루틴과 일정이 모두 있으면 공간 나눔, 글자가 크면 줄 수를 줄임
    private var maxRoutines: Int {
        WDS.rowLimit(entry.appointments.isEmpty ? 8 : 4, for: typeSize)
    }
    private var maxAppointments: Int {
        WDS.rowLimit(entry.routines.isEmpty ? 8 : 3, for: typeSize)
    }

    var body: some View {
        Group {
            if !entry.isPreview, let reason = WidgetDataStore.lockReason {
                WidgetLockedView(family: .systemLarge, reason: reason)   // D13: 위젯은 Pro 전용
            } else {
                unlockedContent
            }
        }
        .dynamicTypeSize(...WDS.maxTypeSize)
    }

    private var unlockedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── 헤더 ──
            dateHeader
                .padding(.bottom, 10)

            if entry.routines.isEmpty && entry.appointments.isEmpty {
                Spacer()
                emptyState
                Spacer()
            } else {
                // ── 루틴 섹션 ──
                if !entry.routines.isEmpty {
                    routineSection
                }

                // ── 일정 섹션 (구분선 대신 간격으로 나눕니다) ──
                if !entry.appointments.isEmpty {
                    appointmentSection
                        .padding(.top, entry.routines.isEmpty ? 0 : 12)
                }

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) {
            WDS.Colors.background
        }
        .widgetURL(URL(string: "mora://tab/routine"))
    }

    // MARK: - Date Header
    private var dateHeader: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(WidgetL.today)
                    .font(WDS.Typography.labelSm)
                    .foregroundStyle(WDS.Colors.primary)

                // 기기 언어가 아니라 앱 언어로 날짜·요일을 씁니다.
                Text(entry.date.formatted(
                    .dateTime.month().day().weekday(.wide).locale(WidgetL.locale)
                ))
                    .font(WDS.Typography.headline)
                    .foregroundStyle(WDS.Colors.onSurfaceVariant)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 8)

            // 전체 완료 상태
            if routineTotal > 0 {
                routineProgressBadge
            }
        }
    }

    // MARK: - Routine Progress Badge
    private var routineProgressBadge: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(WDS.Colors.onSurfaceVariant.opacity(0.1), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: routineProgress)
                    .stroke(WDS.Colors.tertiary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)

            Text("\(routineCompleted)/\(routineTotal)")
                .font(WDS.Typography.labelSm)
                .foregroundStyle(WDS.Colors.onSurfaceVariant)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(WDS.Colors.surfaceContainerLow)
        )
    }

    // MARK: - Section Header
    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(WDS.Typography.labelSm)
                .accessibilityHidden(true)
            Text(title)
                .font(WDS.Typography.labelSm)
        }
        .foregroundStyle(WDS.Colors.onSurfaceMeta)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Routine Section (Interactive)
    private var routineSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(WidgetL.routines, icon: "arrow.trianglehead.2.counterclockwise")
                .padding(.bottom, 2)

            // 루틴 목록 (동적 개수)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(entry.routines.prefix(maxRoutines)) { routine in
                    WidgetTaskRow(task: routine, hitSize: 28)
                }

                if entry.routines.count > maxRoutines {
                    Text(WidgetL.more(entry.routines.count - maxRoutines))
                        .font(WDS.Typography.caption)
                        .foregroundStyle(WDS.Colors.onSurfaceMeta)
                        .padding(.leading, 32)
                }
            }
            .padding(.leading, -4)   // 넓힌 누름 영역만큼 체크 원을 섹션 제목에 맞춥니다
        }
    }

    // MARK: - Appointment Section (Interactive)
    private var appointmentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(WidgetL.appointments, icon: "calendar")
                .padding(.bottom, 2)

            // 일정 목록 (동적 개수)
            ForEach(entry.appointments.prefix(maxAppointments)) { appointment in
                HStack(spacing: 8) {
                    // 시간 태그 (잘리지 않게 필요한 만큼 폭을 씁니다)
                    Text(appointment.displayTime ?? "--:--")
                        .font(WDS.Typography.caption.weight(.semibold))
                        .foregroundStyle(appointment.displayTime == nil ? WDS.Colors.onSurfaceMeta : WDS.Colors.primary)
                        .fixedSize()
                        .frame(minWidth: 56, alignment: .leading)
                        .accessibilityHidden(appointment.displayTime == nil)

                    VStack(alignment: .leading, spacing: 0) {
                        Text(appointment.task)
                            .font(WDS.Typography.bodyMd)
                            .foregroundStyle(
                                appointment.isCompleted
                                    ? WDS.Colors.onSurfaceMeta
                                    : WDS.Colors.onSurfaceVariant
                            )
                            .strikethrough(appointment.isCompleted)
                            .lineLimit(1)
                            .accessibilityHidden(true)   // 이름은 완료 버튼이 읽어 줍니다

                        if let label = appointment.recurrenceLabel {
                            Text(label)
                                .font(WDS.Typography.caption)
                                .foregroundStyle(WDS.Colors.onSurfaceMeta)
                        }
                    }

                    Spacer(minLength: 4)

                    // 인터랙티브 완료 토글
                    WidgetCompleteButton(task: appointment, hitSize: 28)
                        .padding(.trailing, -4)
                }
                .frame(minHeight: 28)
            }

            if entry.appointments.count > maxAppointments {
                Text(WidgetL.more(entry.appointments.count - maxAppointments))
                    .font(WDS.Typography.caption)
                    .foregroundStyle(WDS.Colors.onSurfaceMeta)
                    .padding(.leading, 64)
            }
        }
    }

    // MARK: - Empty State
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 32))
                .foregroundStyle(WDS.Colors.primary)
                .accessibilityHidden(true)

            Text(WidgetL.noTasks)
                .font(WDS.Typography.titleSm)
                .foregroundStyle(WDS.Colors.onSurfaceVariant)

            Text(WidgetL.tapToAdd)
                .font(WDS.Typography.caption)
                .foregroundStyle(WDS.Colors.primary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Widget Configuration
struct DailyOverviewWidget: Widget {
    let kind = "DailyOverviewWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DailyOverviewProvider()) { entry in
            DailyOverviewWidgetView(entry: entry)
        }
        .configurationDisplayName("Today")
        .description("Today's routines and plans in one place.")
        .supportedFamilies([.systemLarge])
    }
}
