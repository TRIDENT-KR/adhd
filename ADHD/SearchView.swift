import SwiftUI
import SwiftData

// MARK: - Search View
/// 전체 태스크 검색 — RoutineView/PlannerView 헤더의 돋보기 아이콘으로 진입
struct SearchView: View {
    @Query(sort: \AppTask.time) private var allTasks: [AppTask]
    @EnvironmentObject private var taskManager: TaskManager

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    /// 탭 전환 + PlannerView 날짜 이동용 콜백
    var onSelectAppointment: ((Date) -> Void)?

    private var filteredTasks: [AppTask] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let query = searchText.lowercased()
        return allTasks.filter { $0.task.localizedCaseInsensitiveContains(query) }
    }

    private var filteredRoutines: [AppTask] {
        filteredTasks.filter { $0.category == "Routine" }
    }

    private var filteredAppointments: [AppTask] {
        filteredTasks.filter { $0.category == "Appointment" }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Search bar
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.6))

                    TextField(L.search.placeholder, text: $searchText)
                        .focused($isSearchFocused)
                        .font(DesignSystem.Typography.bodyMd)
                        .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                        .submitLabel(.search)

                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(DesignSystem.Colors.onSurfaceVariant.opacity(0.06))
                .cornerRadius(14)
                .padding(.horizontal, 20)
                .padding(.top, 8)

                if searchText.isEmpty {
                    // Idle state
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.15))
                            .accessibilityHidden(true)
                        Text(L.search.hint)
                            .font(DesignSystem.Typography.bodyMd)
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.6))
                    }
                    Spacer()
                } else if filteredTasks.isEmpty {
                    // No results
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.15))
                            .accessibilityHidden(true)
                        Text(L.search.noResults)
                            .font(DesignSystem.Typography.bodyMd)
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.6))
                    }
                    Spacer()
                } else {
                    // Results
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if !filteredRoutines.isEmpty {
                                sectionHeader(L.voice.confirmRoutine)
                                ForEach(filteredRoutines) { task in
                                    SearchResultRow(task: task)
                                        .onTapGesture {
                                            dismiss()
                                        }
                                }
                            }

                            if !filteredAppointments.isEmpty {
                                sectionHeader(L.voice.confirmAppointment)
                                ForEach(filteredAppointments) { task in
                                    SearchResultRow(task: task, dateFormatter: Self.dateFormatter)
                                        .onTapGesture {
                                            if let date = task.date {
                                                onSelectAppointment?(date)
                                            }
                                            dismiss()
                                        }
                                }
                            }
                        }
                        .padding(.top, 8)
                    }
                }
            }
            .background(DesignSystem.Colors.background.ignoresSafeArea())
            .navigationTitle(Text(verbatim: "Search"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L.settings.done) { dismiss() }
                        .foregroundColor(DesignSystem.Colors.primary)
                }
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isSearchFocused = true
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.7))
            .textCase(.uppercase)
            .tracking(0.5)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 8)
    }
}

// MARK: - Search Result Row
struct SearchResultRow: View {
    let task: AppTask
    var dateFormatter: DateFormatter? = nil

    var body: some View {
        HStack(spacing: 14) {
            // Completion indicator
            ZStack {
                Circle()
                    .stroke(DesignSystem.Colors.onSurfaceVariant.opacity(0.4), lineWidth: 1.5)
                    .frame(width: 24, height: 24)
                if task.isCompleted {
                    Circle()
                        .fill(DesignSystem.Colors.tertiary)
                        .frame(width: 24, height: 24)
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.white)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(task.task)
                    .font(DesignSystem.Typography.bodyMd)
                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                    .strikethrough(task.isCompleted)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let time = task.time, !time.isEmpty {
                        Text(time)
                            .font(DesignSystem.Typography.labelSm)
                    }
                    if let date = task.date, let fmt = dateFormatter {
                        Text(fmt.string(from: date))
                            .font(DesignSystem.Typography.labelSm)
                    }
                    if task.isRecurring, let label = task.recurrenceLabel {
                        HStack(spacing: 2) {
                            Image(systemName: "repeat")
                                .font(.caption2)
                            Text(label)
                                .font(.caption2)
                        }
                    }
                }
                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.6))
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.4))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.task)\(task.isCompleted ? ", completed" : "")\(task.time.map { ", \($0)" } ?? "")")
        .accessibilityHint("Double tap to navigate to this task")
    }
}
