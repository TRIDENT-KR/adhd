import SwiftUI
import SwiftData

struct RoutineView: View {
    // MARK: - SwiftData Queries
    /// category == "Routine" 데이터만 필터링 (날짜 무관, 매일 반복)
    @Query(filter: #Predicate<AppTask> { $0.category == "Routine" },
           sort: \.time)
    private var routines: [AppTask]

    /// category == "Appointment" 데이터 (날짜 필터링은 computed property에서)
    @Query(filter: #Predicate<AppTask> { $0.category == "Appointment" },
           sort: \.time)
    private var allAppointments: [AppTask]

    /// 오늘 날짜의 Appointment만 반환 (반복 일정 포함), 사용자 정렬 > 시간순
    private var todayAppointments: [AppTask] {
        let today = Date()
        return allAppointments
            .filter { $0.occursOn(today) }
            .sorted { a, b in
                if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
                return a.sortableTime < b.sortableTime
            }
    }

    /// 오늘의 Routines (매일 반복 혹은 오늘 날짜 지정), 사용자 정렬 > 시간순
    private var todayRoutines: [AppTask] {
        let today = Date()
        return routines
            .filter { $0.occursOn(today) }
            .sorted { a, b in
                if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
                return a.sortableTime < b.sortableTime
            }
    }

    @EnvironmentObject private var taskManager: TaskManager
    @Environment(\.modelContext) private var modelContext

    @ObservedObject var langManager = LocalizationManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var activeTab: TabSelection
    @State private var editingTaskId: UUID?
    @State private var selectedSection: RoutineSection = .routines
    @State private var showSearch = false
    @State private var isReordering = false

    enum RoutineSection: CaseIterable {
        case routines, tasks

        var label: String {
            switch self {
            case .routines: return L.routineDailySection
            case .tasks: return L.routineTodaySection
            }
        }
    }
    var body: some View {
        ZStack(alignment: .bottom) {
            DesignSystem.Colors.background
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 48) {

                    // 제목 + 검색 버튼
                    HStack {
                        Text(verbatim: "Routine")
                            .font(DesignSystem.Typography.displayLg)
                            .foregroundColor(DesignSystem.Colors.primary)
                            .tracking(-0.5)
                        Spacer()
                        Button(action: { showSearch = true }) {
                            Image(systemName: "magnifyingglass")
                                .font(.title3.weight(.light))
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.6))
                                .padding(12)
                                .contentShape(Circle())
                        }
                        .buttonStyle(NoEffectButtonStyle())
                        .accessibilityLabel("Search tasks")
                        .frame(minWidth: 44, minHeight: 44)
                    }
                    .padding(.top, 16)
                    .padding(.leading, 32)
                    .padding(.trailing, 20)

                    // 섹션 토글 + 정렬 버튼
                    HStack(spacing: 12) {
                        ForEach(RoutineSection.allCases, id: \.self) { section in
                            let isSelected = selectedSection == section
                            Button(action: {
                                let anim: Animation? = reduceMotion ? .none : .spring(response: 0.3, dampingFraction: 0.8)
                                withAnimation(anim) {
                                    selectedSection = section
                                    isReordering = false
                                }
                            }) {
                                Text(section.label)
                                    .font(DesignSystem.Typography.labelSm)
                                    .tracking(0.3)
                                    .foregroundColor(isSelected ? .white : DesignSystem.Colors.onSurfaceVariant)
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 16)
                                    .background(
                                        Capsule().fill(isSelected ? DesignSystem.Colors.primary : DesignSystem.Colors.onSurfaceVariant.opacity(0.08))
                                    )
                            }
                            .buttonStyle(PlainButtonStyle())
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                        Spacer()

                        // 정렬 모드 토글
                        Button(action: {
                            let anim: Animation? = reduceMotion ? .none : .spring(response: 0.3, dampingFraction: 0.8)
                            withAnimation(anim) {
                                isReordering.toggle()
                                if isReordering { editingTaskId = nil }
                            }
                        }) {
                            Image(systemName: isReordering ? "checkmark.circle.fill" : "arrow.up.arrow.down")
                                .font(.body.weight(.medium))
                                .foregroundColor(isReordering ? DesignSystem.Colors.tertiary : DesignSystem.Colors.onSurfaceVariant.opacity(0.6))
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(isReordering ? "Finish reordering" : "Reorder tasks")
                    }
                    .padding(.horizontal, 32)

                    // 선택된 섹션의 태스크 목록
                    Group {
                        let currentTasks = selectedSection == .routines ? todayRoutines : todayAppointments

                        if currentTasks.isEmpty {
                            // Empty State: 안정적인 레이아웃 구조로 변경 (GeometryReader 제거)
                            VStack(spacing: 20) {
                                Image(systemName: "mic.fill")
                                    .font(.system(size: 48))
                                    .foregroundColor(DesignSystem.Colors.primary.opacity(0.5))
                                    .accessibilityHidden(true)

                                Text(selectedSection == .routines
                                     ? L.routineEmptyRoutine
                                     : L.routineEmptyTask)
                                    .font(DesignSystem.Typography.bodyMd)
                                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.7))
                            }
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 300)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if reduceMotion { activeTab = .voice } else { withAnimation(.spring()) { activeTab = .voice } }
                            }
                            .accessibilityLabel("No tasks yet. Tap to add tasks with voice")
                            .accessibilityAddTraits(.isButton)
                        } else if isReordering {
                            // 정렬 모드: 부드러운 드래그 리오더
                            SmoothTaskReorderList(tasks: currentTasks, taskManager: taskManager)
                        } else {
                            let (incomplete, completed) = currentTasks.partitioned { !$0.isCompleted }
                            LazyVStack(spacing: 32) {
                                ForEach(incomplete) { task in
                                    TaskRow(task: task, editingTaskId: $editingTaskId)
                                }
                                ForEach(completed) { task in
                                    TaskRow(task: task, editingTaskId: $editingTaskId)
                                }
                            }
                        }
                    }
                    .id(selectedSection) // 섹션 전환 시 화면 튐 방지

                    Spacer(minLength: 140)
                }
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .sheet(isPresented: $showSearch) {
            SearchView()
        }
    }

}

// MARK: - Task Row Component
struct TaskRow: View {
    var task: AppTask
    @Binding var editingTaskId: UUID?

    @EnvironmentObject private var taskManager: TaskManager
    @Environment(\.modelContext) private var modelContext

    @FocusState private var isTitleFocused: Bool
    @State private var showingTimePicker = false
    @State private var localTaskName: String = ""
    @State private var localTime: String     = ""
    @State private var localUrgency: Urgency  = .strong
    @State private var cachedCategoryIcon: String = "circle.fill"

    var isEditing: Bool { editingTaskId == task.id }
    var isDimmed:  Bool { editingTaskId != nil && editingTaskId != task.id }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {

            // ── 체크박스 (맨 왼쪽) ──
            Button(action: {
                withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.3)) {
                    taskManager.toggleCompletion(of: task)
                }
                Haptic.impact(.medium)
            }) {
                ZStack {
                    Circle()
                        .stroke(DesignSystem.Colors.onSurfaceVariant.opacity(0.3), lineWidth: 1.5)
                        .frame(width: 32, height: 32)
                    if task.isCompleted {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.45))
                    }
                }
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .disabled(isEditing)
            .accessibilityLabel(task.isCompleted ? "\(task.task), completed" : "\(task.task), not completed")
            .accessibilityHint("Double tap to toggle completion")

            if isEditing {
                // ── 편집 모드 ──
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Task", text: $localTaskName)
                        .focused($isTitleFocused)
                        .font(DesignSystem.Typography.bodyMd)
                        .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                        .submitLabel(.done)
                        .onSubmit { finishEditing() }

                    HStack(spacing: 8) {
                        Text(localTime.isEmpty ? "Set Time" : localTime)
                            .font(DesignSystem.Typography.labelSm)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(DesignSystem.Colors.onSurfaceVariant.opacity(0.1))
                            .cornerRadius(6)
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                            .onTapGesture { showingTimePicker = true }
                            .sheet(isPresented: $showingTimePicker) {
                                TimePickerModal(timeString: $localTime, isPresented: $showingTimePicker)
                            }

                        Button(action: {
                            localUrgency = (localUrgency == .weak) ? .strong : .weak
                            Haptic.impact(.light)
                        }) {
                            HStack(spacing: 3) {
                                Image(systemName: localUrgency == .strong ? "bolt.fill" : "bolt")
                                    .font(.caption2.weight(.semibold))
                                Text(localUrgency == .strong ? "Strong" : "Weak")
                                    .font(.caption2.weight(.medium))
                            }
                            .foregroundColor(localUrgency == .strong ? .orange : DesignSystem.Colors.onSurfaceVariant.opacity(0.6))
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background((localUrgency == .strong ? Color.orange : DesignSystem.Colors.onSurfaceVariant).opacity(0.12))
                            .cornerRadius(6)
                        }
                        .buttonStyle(NoEffectButtonStyle())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // 삭제 + 완료
                HStack(spacing: 4) {
                    Button(action: {
                        withAnimation {
                            taskManager.delete(task: task)
                            editingTaskId = nil
                        }
                        Haptic.impact(.medium)
                    }) {
                        Image(systemName: "trash")
                            .font(.footnote)
                            .foregroundColor(.red.opacity(0.7))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Delete task")

                    Button(action: { finishEditing() }) {
                        Image(systemName: "checkmark")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.4))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Save changes")
                }

            } else {
                // ── 일반 모드 ──
                VStack(alignment: .leading, spacing: 0) {

                    // 1행: 아이콘 + 제목
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: cachedCategoryIcon)
                            .font(.footnote)
                            .foregroundColor(DesignSystem.Colors.primary.opacity(task.isCompleted ? 0.3 : 0.6))
                            .frame(width: 18)
                            .padding(.top, 3)
                            .accessibilityHidden(true)

                        Text(task.task)
                            .font(DesignSystem.Typography.bodyMd)
                            .foregroundColor(
                                task.isCompleted
                                    ? DesignSystem.Colors.onSurfaceVariant.opacity(0.38)
                                    : DesignSystem.Colors.onSurfaceVariant
                            )
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // 2행: 시간 + 반복 + 알림 (아이콘 좌측 정렬)
                    HStack(spacing: 5) {
                        if let time = task.time, !time.isEmpty {
                            if task.isRecurring {
                                Image(systemName: "repeat")
                                    .font(.system(size: 8))
                                    .foregroundColor(DesignSystem.Colors.primary.opacity(0.45))
                                    .accessibilityHidden(true)
                            }
                            Text(time)
                                .font(DesignSystem.Typography.labelSm)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(
                                    task.isCompleted ? 0.3 : 0.5))
                        }
                        Image(systemName: task.urgency == .strong ? "bolt.fill" : "bolt")
                            .font(.system(size: 10))
                            .foregroundColor(task.urgency == .strong
                                ? .orange.opacity(0.8)
                                : DesignSystem.Colors.onSurfaceVariant.opacity(0.18))
                            .accessibilityLabel(task.urgency == .strong ? "High urgency" : "Low urgency")
                    }
                    .padding(.top, 5)

                    // 3행: WeeklyBar (Routine만)
                    if task.category == "Routine" {
                        WeeklyBar(task: task)
                            .padding(.top, 14)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation { startEditing() }
                    Haptic.impact(.light)
                }
                .accessibilityLabel("Edit \(task.task)")
                .accessibilityHint("Double tap to edit")
            }
        }
        .padding(.horizontal, 32)
        .opacity(isDimmed ? 0.3 : 1.0)
        .onAppear {
            localTaskName = task.task
            localTime     = task.time ?? ""
            cachedCategoryIcon = CategoryIconResolver.resolveIcon(for: task.task, category: task.category)
        }
        .onChange(of: editingTaskId) { oldValue, newValue in
            if newValue == task.id {
                localTaskName = task.task
                localTime     = task.time ?? ""
            } else {
                isTitleFocused = false
            }
        }
        .task(id: editingTaskId) {
            guard editingTaskId == task.id else { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
            isTitleFocused = true
        }
    }

    private func finishEditing() {
        guard editingTaskId == task.id else { return }
        task.task    = localTaskName
        task.time    = localTime.isEmpty ? nil : localTime
        task.urgency = localUrgency
        taskManager.update(task: task)
        cachedCategoryIcon = CategoryIconResolver.resolveIcon(for: localTaskName, category: task.category)
        editingTaskId = nil
        Haptic.impact(.light)
    }

    private func startEditing() {
        localUrgency  = task.urgency
        editingTaskId = task.id
        Haptic.impact(.medium)
    }
}

// MARK: - Weekly Bar
/// 루틴 카드 하단에 표시되는 이번 주 완료 현황 (M T W T F S S)
struct WeeklyBar: View {
    let task: AppTask

    @EnvironmentObject private var taskManager: TaskManager

    private let dayLabels = ["M", "T", "W", "T", "F", "S", "S"]

    /// ISO 8601 기준 오늘 요일 인덱스 (0=월, 6=일)
    private var todayIndex: Int {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = .current
        return cal.component(.weekday, from: Date()) - 1
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<7, id: \.self) { i in
                VStack(spacing: 6) {
                    Text(dayLabels[i])
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(
                            i == todayIndex
                                ? DesignSystem.Colors.primary
                                : DesignSystem.Colors.onSurfaceVariant.opacity(0.35)
                        )

                    dayButton(for: i)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(weeklyAccessibilityLabel)
    }

    @ViewBuilder
    private func dayButton(for i: Int) -> some View {
        if i < todayIndex {
            // 지난 요일: 탭으로 토글 가능
            let completed = task.weeklyCompletions.indices.contains(i) && task.weeklyCompletions[i]
            Button(action: {
                guard task.weeklyCompletions.indices.contains(i) else { return }
                task.weeklyCompletions[i].toggle()
                taskManager.safeSave()
                Haptic.impact(.light)
            }) {
                ZStack {
                    Circle()
                        .fill(completed
                            ? DesignSystem.Colors.tertiary.opacity(0.85)
                            : DesignSystem.Colors.onSurfaceVariant.opacity(0.08))
                        .frame(width: 26, height: 26)
                    if completed {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
            }
            .buttonStyle(NoEffectButtonStyle())
            .frame(minWidth: 36, minHeight: 36)
            .contentShape(Rectangle())
        } else if i == todayIndex {
            // 오늘: 테두리 강조, isCompleted 실시간 반영 (탭 불가 — 메인 체크박스로)
            let completed = task.isCompleted
            ZStack {
                Circle()
                    .fill(completed ? DesignSystem.Colors.tertiary : Color.clear)
                    .frame(width: 26, height: 26)
                Circle()
                    .stroke(DesignSystem.Colors.primary, lineWidth: 1.5)
                    .frame(width: 26, height: 26)
                if completed {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .frame(width: 36, height: 36)
        } else {
            // 미래 요일: 작은 점
            Circle()
                .fill(DesignSystem.Colors.onSurfaceVariant.opacity(0.12))
                .frame(width: 6, height: 6)
                .frame(width: 36, height: 36)
        }
    }

    private var weeklyAccessibilityLabel: String {
        let days = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        var parts: [String] = []
        for i in 0..<7 {
            if i < todayIndex {
                let done = task.weeklyCompletions.indices.contains(i) && task.weeklyCompletions[i]
                parts.append("\(days[i]): \(done ? "completed" : "missed")")
            } else if i == todayIndex {
                parts.append("\(days[i]): today, \(task.isCompleted ? "completed" : "not completed")")
            }
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Preview
struct RoutineView_Previews: PreviewProvider {
    static var previews: some View {
        RoutineView(activeTab: .constant(.routine))
            .environmentObject(TaskManager())
    }
}

// MARK: - Time Picker Modal
struct TimePickerModal: View {
    @Binding var timeString: String
    @Binding var isPresented: Bool
    @State private var selectedDate: Date

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale     = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "hh:mm a"
        return f
    }()

    init(timeString: Binding<String>, isPresented: Binding<Bool>) {
        self._timeString   = timeString
        self._isPresented  = isPresented

        if let date = Self.timeFormatter.date(from: timeString.wrappedValue) {
            self._selectedDate = State(initialValue: date)
        } else {
            self._selectedDate = State(initialValue: Date())
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Select Time")
                .font(DesignSystem.Typography.titleSm)
                .padding(.top, 32)

            DatePicker("", selection: $selectedDate, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()

            Button("Done") {
                timeString  = Self.timeFormatter.string(from: selectedDate)
                isPresented = false
            }
            .font(.body.weight(.semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Capsule().fill(DesignSystem.Colors.primary))
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
        .presentationDetents([.height(350)])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Swipe-to-Delete Modifier
struct SwipeToDeleteModifier: ViewModifier {
    let onDelete: () -> Void
    @State private var offset: CGFloat = 0
    @State private var showDelete = false
    private let threshold: CGFloat = -80

    func body(content: Content) -> some View {
        ZStack(alignment: .trailing) {
            // Delete background
            if showDelete {
                HStack {
                    Spacer()
                    Button(action: {
                        withAnimation(.spring(response: 0.3)) {
                            offset = -UIScreen.main.bounds.width
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            onDelete()
                        }
                    }) {
                        Image(systemName: "trash.fill")
                            .font(.body)
                            .foregroundColor(.white)
                            .frame(width: 60, height: 50)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.red.opacity(0.8)))
                    }
                    .padding(.trailing, 32)
                }
            }

            content
                .offset(x: offset)
                .gesture(
                    DragGesture(minimumDistance: 20)
                        .onChanged { value in
                            if value.translation.width < 0 {
                                offset = value.translation.width
                                showDelete = offset < threshold / 2
                            }
                        }
                        .onEnded { value in
                            withAnimation(.spring(response: 0.3)) {
                                if value.translation.width < threshold {
                                    offset = threshold
                                    showDelete = true
                                } else {
                                    offset = 0
                                    showDelete = false
                                }
                            }
                        }
                )
        }
    }
}

extension View {
    func swipeToDelete(onDelete: @escaping () -> Void) -> some View {
        modifier(SwipeToDeleteModifier(onDelete: onDelete))
    }
}

// MARK: - Array Partition Helper
private extension Array {
    /// Single-pass partition into (matching, non-matching)
    func partitioned(by predicate: (Element) -> Bool) -> ([Element], [Element]) {
        var matching: [Element] = []
        var rest: [Element] = []
        for element in self {
            if predicate(element) { matching.append(element) }
            else { rest.append(element) }
        }
        return (matching, rest)
    }
}

