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
            routines: TodayRoutinesProvider.previewRoutines,
            appointments: Self.previewAppointments,
            isPreview: true
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (DailyOverviewEntry) -> Void) {
        let payload = WidgetDataStore.read()
        completion(DailyOverviewEntry(
            date: .now,
            routines: payload?.routines ?? TodayRoutinesProvider.previewRoutines,
            appointments: payload?.appointments ?? Self.previewAppointments,
            isPreview: context.isPreview
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DailyOverviewEntry>) -> Void) {
        let payload = WidgetDataStore.read()
        let entry = DailyOverviewEntry(
            date: .now,
            routines: payload?.routines ?? [],
            appointments: payload?.appointments ?? [],
            isPreview: false
        )
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: .now)!
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    static let previewAppointments: [WidgetTaskSnapshot] = [
        .init(id: UUID(), task: "Team Meeting", time: "02:00 PM", category: "Appointment", isCompleted: false, recurrenceLabel: "weekly"),
        .init(id: UUID(), task: "Dentist", time: "05:30 PM", category: "Appointment", isCompleted: false, recurrenceLabel: nil),
    ]
}

// MARK: - Large Widget View
struct DailyOverviewWidgetView: View {
    let entry: DailyOverviewEntry

    private var routineCompleted: Int { entry.routines.filter(\.isCompleted).count }
    private var routineTotal: Int { entry.routines.count }
    private var routineProgress: Double { routineTotal > 0 ? Double(routineCompleted) / Double(routineTotal) : 0 }

    // 동적으로 표시 개수 조절: 루틴과 일정이 모두 있으면 공간 나눔
    private var maxRoutines: Int {
        entry.appointments.isEmpty ? 8 : 5
    }
    private var maxAppointments: Int {
        entry.routines.isEmpty ? 8 : 4
    }

    var body: some View {
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

                // ── 구분선 ──
                if !entry.routines.isEmpty && !entry.appointments.isEmpty {
                    Divider()
                        .background(WDS.Colors.onSurfaceVariant.opacity(0.1))
                        .padding(.vertical, 6)
                }

                // ── 일정 섹션 ──
                if !entry.appointments.isEmpty {
                    appointmentSection
                }

                Spacer(minLength: 0)
            }
        }
        .padding(14)
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
                    .font(WDS.Typography.caption)
                    .foregroundStyle(WDS.Colors.primary)

                Text(entry.date, format: .dateTime.month().day().weekday(.wide))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(WDS.Colors.onSurfaceVariant)
            }

            Spacer()

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
            .frame(width: 20, height: 20)

            Text("\(routineCompleted)/\(routineTotal)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(WDS.Colors.onSurfaceVariant.opacity(0.6))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(WDS.Colors.surfaceContainerLow)
        )
    }

    // MARK: - Routine Section (Interactive)
    private var routineSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            // 섹션 헤더
            HStack(spacing: 4) {
                Image(systemName: "arrow.trianglehead.2.counterclockwise")
                    .font(.system(size: 9, weight: .semibold))
                Text(WidgetL.routines)
                    .font(WDS.Typography.labelSm)
            }
            .foregroundStyle(WDS.Colors.onSurfaceVariant.opacity(0.5))
            .padding(.bottom, 2)

            // 루틴 목록 (동적 개수)
            ForEach(entry.routines.prefix(maxRoutines)) { routine in
                HStack(spacing: 7) {
                    // 인터랙티브 완료 토글
                    Button(intent: ToggleTaskIntent(taskID: routine.id.uuidString)) {
                        Image(systemName: routine.isCompleted ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 13))
                            .foregroundStyle(routine.isCompleted ? WDS.Colors.tertiary : WDS.Colors.onSurfaceVariant.opacity(0.25))
                    }
                    .buttonStyle(.plain)

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

                    if let time = routine.time, !time.isEmpty {
                        Text(time)
                            .font(WDS.Typography.caption)
                            .foregroundStyle(WDS.Colors.onSurfaceVariant.opacity(0.35))
                    }
                }
                .padding(.vertical, 1)
            }

            if entry.routines.count > maxRoutines {
                Text("+\(entry.routines.count - maxRoutines) \(WidgetL.moreTasks)")
                    .font(WDS.Typography.caption)
                    .foregroundStyle(WDS.Colors.onSurfaceVariant.opacity(0.35))
                    .padding(.leading, 20)
            }
        }
    }

    // MARK: - Appointment Section (Interactive)
    private var appointmentSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            // 섹션 헤더
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                    .font(.system(size: 9, weight: .semibold))
                Text(WidgetL.appointments)
                    .font(WDS.Typography.labelSm)
            }
            .foregroundStyle(WDS.Colors.onSurfaceVariant.opacity(0.5))
            .padding(.bottom, 2)

            // 일정 목록 (동적 개수)
            ForEach(entry.appointments.prefix(maxAppointments)) { appointment in
                HStack(spacing: 7) {
                    // 시간 태그
                    if let time = appointment.time, !time.isEmpty {
                        Text(time)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(WDS.Colors.primary)
                            .frame(width: 58, alignment: .leading)
                    } else {
                        Text("--:--")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(WDS.Colors.onSurfaceVariant.opacity(0.3))
                            .frame(width: 58, alignment: .leading)
                    }

                    // 세로 구분 바
                    RoundedRectangle(cornerRadius: 1)
                        .fill(WDS.Colors.primary.opacity(0.4))
                        .frame(width: 2, height: 16)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(appointment.task)
                            .font(WDS.Typography.bodyMd)
                            .foregroundStyle(
                                appointment.isCompleted
                                    ? WDS.Colors.onSurfaceVariant.opacity(0.35)
                                    : WDS.Colors.onSurfaceVariant
                            )
                            .strikethrough(appointment.isCompleted, color: WDS.Colors.onSurfaceVariant.opacity(0.3))
                            .lineLimit(1)

                        if let label = appointment.recurrenceLabel {
                            Text(label)
                                .font(WDS.Typography.caption)
                                .foregroundStyle(WDS.Colors.onSurfaceVariant.opacity(0.35))
                        }
                    }

                    Spacer()

                    // 인터랙티브 완료 토글
                    Button(intent: ToggleTaskIntent(taskID: appointment.id.uuidString)) {
                        Image(systemName: appointment.isCompleted ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 13))
                            .foregroundStyle(appointment.isCompleted ? WDS.Colors.tertiary : WDS.Colors.onSurfaceVariant.opacity(0.25))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
            }

            if entry.appointments.count > maxAppointments {
                Text("+\(entry.appointments.count - maxAppointments) \(WidgetL.moreTasks)")
                    .font(WDS.Typography.caption)
                    .foregroundStyle(WDS.Colors.onSurfaceVariant.opacity(0.35))
                    .padding(.leading, 60)
            }
        }
    }

    // MARK: - Empty State
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 32))
                .foregroundStyle(WDS.Colors.primaryFixedDim.opacity(0.5))

            Text(WidgetL.noTasks)
                .font(WDS.Typography.bodyMd)
                .foregroundStyle(WDS.Colors.onSurfaceVariant.opacity(0.5))

            Text(WidgetL.tapToAdd)
                .font(WDS.Typography.caption)
                .foregroundStyle(WDS.Colors.primary.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Widget Configuration
struct DailyOverviewWidget: Widget {
    let kind = "DailyOverviewWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DailyOverviewProvider()) { entry in
            DailyOverviewWidgetView(entry: entry)
        }
        .configurationDisplayName(WidgetL.today)
        .description("Full overview of your routines and appointments")
        .supportedFamilies([.systemLarge])
    }
}
