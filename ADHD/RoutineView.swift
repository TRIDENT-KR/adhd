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
    @EnvironmentObject private var authManager: AuthManager
    @Environment(\.modelContext) private var modelContext

    @ObservedObject var langManager = LocalizationManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var activeTab: TabSelection
    /// 수정 시트로 연 할 일 (카드를 누르면 열림)
    @State private var editingTask: AppTask?
    @State private var selectedSection: RoutineSection = .routines
    @State private var showSearch = false
    @State private var showQuickAdd = false
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
                VStack(alignment: .leading, spacing: 24) {

                    // 제목 + 더보기(검색·순서 변경) + 추가
                    ScreenHeader(title: "Routine", addLabel: L.quickAdd.title, onAdd: { showQuickAdd = true }) {
                        Button(action: { showSearch = true }) {
                            Label(L.t("Search tasks", "일정 검색", "タスクを検索"), systemImage: "magnifyingglass")
                        }
                        Button(action: toggleReordering) {
                            Label(L.t("Reorder tasks", "일정 순서 변경", "タスクを並べ替える"), systemImage: "arrow.up.arrow.down")
                        }
                    }
                    .padding(.top, 16)
                    .padding(.horizontal, 20)

                    // 섹션 토글 (순서 변경 중에는 '완료' 버튼)
                    HStack(spacing: 8) {
                        ForEach(RoutineSection.allCases, id: \.self) { section in
                            let isSelected = selectedSection == section
                            Button(action: {
                                let anim: Animation? = reduceMotion ? .none : .timingCurve(0.4, 0, 0.2, 1, duration: 0.3)
                                withAnimation(anim) {
                                    selectedSection = section
                                    isReordering = false
                                }
                            }) {
                                Text(section.label)
                                    .lineLimit(1)
                                    .font(.subheadline.weight(isSelected ? .bold : .medium))
                                    .foregroundColor(isSelected ? DesignSystem.Colors.onPrimary : DesignSystem.Colors.onSurfaceVariant)
                                    .padding(.horizontal, 18)
                                    .frame(minHeight: 44)
                                    .background(
                                        Capsule().fill(isSelected ? DesignSystem.Colors.primary : DesignSystem.Colors.surfaceContainerLow)
                                    )
                            }
                            .buttonStyle(PressScaleButtonStyle())
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                        Spacer()

                        if isReordering {
                            Button(action: toggleReordering) {
                                Text(L.t("Done", "완료", "完了"))
                                    .font(.subheadline.weight(.bold))
                                    .foregroundColor(DesignSystem.Colors.tertiary)
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .accessibilityLabel(L.t("Finish reordering", "순서 변경 완료", "並べ替えを完了"))
                        }
                    }
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .padding(.horizontal, 20)

                    // 선택된 섹션의 태스크 목록
                    Group {
                        let currentTasks = selectedSection == .routines ? todayRoutines : todayAppointments

                        if currentTasks.isEmpty {
                            // Empty State: 안정적인 레이아웃 구조로 변경 (GeometryReader 제거)
                            VStack(spacing: 20) {
                                Image(systemName: authManager.accessState.isGuest ? "plus.circle" : "mic.fill")
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
                                if authManager.accessState.isGuest { showQuickAdd = true }
                                else if reduceMotion { activeTab = .voice }
                                else { withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.3)) { activeTab = .voice } }
                            }
                            .accessibilityLabel(authManager.accessState.isGuest
                                ? L.t("No tasks yet. Add a task", "아직 일정이 없어요. 일정 추가", "予定はまだありません。タスクを追加")
                                : L.t("No tasks yet. Add with voice", "아직 일정이 없어요. 음성으로 추가", "予定はまだありません。音声で追加"))
                            .accessibilityAddTraits(.isButton)
                        } else if isReordering {
                            // 정렬 모드: 부드러운 드래그 리오더
                            SmoothTaskReorderList(tasks: currentTasks, taskManager: taskManager)
                        } else {
                            let (incomplete, completed) = currentTasks.partitioned { !$0.isCompleted }
                            LazyVStack(spacing: 12) {
                                ForEach(incomplete) { task in
                                    TaskRow(task: task, onEdit: { editingTask = task })
                                }
                                ForEach(completed) { task in
                                    TaskRow(task: task, onEdit: { editingTask = task })
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
        .sheet(isPresented: $showQuickAdd) {
            QuickAddSheet(mode: selectedSection == .routines ? .routine : .todayTask)
        }
        // 루틴 탭은 항상 오늘을 보여 주므로 '이번만 건너뛰기'도 오늘 회차입니다.
        .sheet(item: $editingTask) { task in
            TaskEditSheet(task: task, viewedDate: Date())
        }
    }

}

extension RoutineView {
    fileprivate func toggleReordering() {
        let anim: Animation? = reduceMotion ? .none : .timingCurve(0.4, 0, 0.2, 1, duration: 0.3)
        withAnimation(anim) {
            isReordering.toggle()
        }
    }
}

// MARK: - Task Row Component
struct TaskRow: View {
    var task: AppTask
    /// 카드를 누르면 수정 시트를 엽니다.
    var onEdit: () -> Void

    @EnvironmentObject private var taskManager: TaskManager

    @State private var cachedCategoryIcon: String = "circle.fill"

    var body: some View {
        HStack(alignment: .top, spacing: 16) {

            // ── 체크박스 (맨 왼쪽) ──
            Button(action: {
                withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.3)) {
                    taskManager.toggleCompletion(of: task)
                }
                Haptic.impact(.medium)
            }) {
                TaskCheckCircle(isCompleted: task.isCompleted)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("\(task.task), \(task.isCompleted ? L.t("completed", "완료", "完了") : L.t("not completed", "미완료", "未完了"))")
            .accessibilityHint(L.t("Double tap to toggle completion", "완료 상태를 바꾸려면 이중 탭하세요", "完了状態を切り替えるにはダブルタップ"))

            VStack(alignment: .leading, spacing: 0) {

                // 1행: 아이콘 + 제목
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: cachedCategoryIcon)
                        .font(.footnote)
                        .dynamicTypeSize(...DynamicTypeSize.large)
                        .foregroundColor(task.isCompleted ? DesignSystem.Colors.onSurfaceMeta : DesignSystem.Colors.primary)
                        .frame(width: 18)
                        .padding(.top, 3)
                        .accessibilityHidden(true)

                    Text(task.task)
                        .font(.body.weight(.semibold))
                        .foregroundColor(task.isCompleted ? DesignSystem.Colors.onSurfaceMeta : DesignSystem.Colors.onSurface)
                        .strikethrough(task.isCompleted, color: DesignSystem.Colors.onSurfaceMeta)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // 2행: 시간 + 반복 + 알림 (아이콘 좌측 정렬)
                HStack(spacing: 5) {
                    if let time = task.time, !time.isEmpty {
                        if task.isRecurring {
                            Image(systemName: "repeat")
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(DesignSystem.Colors.onSurfaceMeta)
                                .accessibilityHidden(true)
                        }
                        Text(StoredTaskFormat.displayTime(time))
                            .font(.subheadline)
                            .foregroundColor(DesignSystem.Colors.onSurfaceMeta)
                    }
                    Image(systemName: task.urgency == .strong ? "bolt.fill" : "bolt")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(task.urgency == .strong ? DesignSystem.Colors.primary : DesignSystem.Colors.onSurfaceMeta)
                        .accessibilityLabel(task.urgency == .strong ? L.voice.urgencyStrong : L.voice.urgencyWeak)
                }
                .padding(.top, 4)

                // 3행: WeeklyBar (Routine만)
                if task.category == "Routine" {
                    WeeklyBar(task: task)
                        .padding(.top, 14)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                Haptic.impact(.light)
                onEdit()
            }
            .accessibilityLabel(L.t("Edit \(task.task)", "\(task.task) 수정", "\(task.task)を編集"))
            .accessibilityHint(L.t("Double tap to edit", "수정하려면 이중 탭하세요", "編集するにはダブルタップ"))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(DesignSystem.Colors.surfaceContainerLow)
        )
        .padding(.horizontal, 20)
        .onAppear {
            cachedCategoryIcon = CategoryIconResolver.resolveIcon(for: task.task, category: task.category)
        }
        // 수정 시트에서 이름을 바꾸면 아이콘도 다시 고릅니다.
        .onChange(of: task.task) { _, newName in
            cachedCategoryIcon = CategoryIconResolver.resolveIcon(for: newName, category: task.category)
        }
    }
}

// MARK: - Weekly Bar
/// 루틴 카드 하단에 표시되는 이번 주 완료 현황 (M T W T F S S)
struct WeeklyBar: View {
    let task: AppTask

    @EnvironmentObject private var taskManager: TaskManager

    /// 월요일부터 시작하는 앱 언어 요일 한 글자 (월화수목금토일 / MTWTFSS / 月火水木金土日)
    private var dayLabels: [String] {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: LocalizationManager.shared.currentLanguage.localeIdentifier)
        let sundayFirst = cal.veryShortStandaloneWeekdaySymbols
        return Array(sundayFirst.dropFirst()) + [sundayFirst[0]]
    }

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
                        .font(.caption.weight(i == todayIndex ? .bold : .medium))
                        .foregroundColor(i == todayIndex ? DesignSystem.Colors.primary : DesignSystem.Colors.onSurfaceMeta)

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
                    if completed {
                        Circle()
                            .fill(DesignSystem.Colors.tertiary)
                            .frame(width: 26, height: 26)
                    } else {
                        // 지나간 미완료: 실패처럼 칠하지 않고 점선 테두리로만 표시
                        Circle()
                            .strokeBorder(DesignSystem.Colors.outline, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                            .frame(width: 26, height: 26)
                    }
                    if completed {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(DesignSystem.Colors.onTertiary)
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
                        .foregroundColor(DesignSystem.Colors.onTertiary)
                }
            }
            .frame(width: 36, height: 36)
        } else {
            // 미래 요일: 작은 점
            Circle()
                .fill(DesignSystem.Colors.outline.opacity(0.4))
                .frame(width: 7, height: 7)
                .frame(width: 36, height: 36)
        }
    }

    private var weeklyAccessibilityLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: LocalizationManager.shared.currentLanguage.rawValue)
        let weekdays = formatter.weekdaySymbols!
        let days = Array(weekdays.dropFirst()) + [weekdays[0]]
        var parts: [String] = []
        for i in 0..<7 {
            if i < todayIndex {
                let done = task.weeklyCompletions.indices.contains(i) && task.weeklyCompletions[i]
                parts.append("\(days[i]): \(done ? L.t("completed", "완료", "完了") : L.t("missed", "미완료", "未完了"))")
            } else if i == todayIndex {
                parts.append("\(days[i]): \(L.calendarToday), \(task.isCompleted ? L.t("completed", "완료", "完了") : L.t("not completed", "미완료", "未完了"))")
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
            .environmentObject(AuthManager())
    }
}

// MARK: - Time Picker Modal
struct TimePickerModal: View {
    @Binding var timeString: String
    @Binding var isPresented: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
            Text(L.t("Select Time", "시간 선택", "時刻を選択"))
                .font(DesignSystem.Typography.titleSm)
                .padding(.top, 32)

            DatePicker("", selection: $selectedDate, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()

            Button(L.settings.done) {
                timeString  = Self.timeFormatter.string(from: selectedDate)
                isPresented = false
            }
            .font(.body.weight(.semibold))
            .foregroundColor(DesignSystem.Colors.onPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Capsule().fill(DesignSystem.Colors.primary))
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
        // 큰 글자(접근성 크기)에서는 고정 높이에 버튼이 잘리므로 전체 높이로 엽니다.
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.height(350)])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Swipe-to-Delete Modifier
struct SwipeToDeleteModifier: ViewModifier {
    /// true면 카드를 밀어 없애지 않고 제자리로 되돌린 뒤 onDelete를 부릅니다 (반복 일정: 건너뛰기/전체 삭제를 먼저 물음).
    var confirmsFirst = false
    let onDelete: () -> Void
    @State private var offset: CGFloat = 0
    @State private var showDelete = false
    @State private var contentWidth: CGFloat = 0
    /// 지연 삭제가 두 번 불리지 않도록 (빠른 연타 방지)
    @State private var isDeleting = false
    private let threshold: CGFloat = -80

    func body(content: Content) -> some View {
        ZStack(alignment: .trailing) {
            // Delete background
            if showDelete {
                HStack {
                    Spacer()
                    Button(action: {
                        if confirmsFirst {
                            withAnimation(.spring(response: 0.3)) {
                                offset = 0
                                showDelete = false
                            }
                            onDelete()
                            return
                        }
                        guard !isDeleting else { return }
                        isDeleting = true
                        withAnimation(.spring(response: 0.3)) {
                            offset = -max(contentWidth, abs(threshold))
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            onDelete()
                        }
                    }) {
                        Image(systemName: "trash.fill")
                            .font(.body)
                            .foregroundColor(DesignSystem.Colors.background)
                            .frame(width: 60, height: 50)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DesignSystem.Colors.error))
                    }
                    .accessibilityLabel(L.t("Delete task", "일정 삭제", "タスクを削除"))
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
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            contentWidth = width
        }
    }
}

extension View {
    func swipeToDelete(confirmsFirst: Bool = false, onDelete: @escaping () -> Void) -> some View {
        modifier(SwipeToDeleteModifier(confirmsFirst: confirmsFirst, onDelete: onDelete))
    }

    /// 반복 일정·루틴을 지울 때: 이번만 건너뛰기 / 모든 회차 삭제 / 취소.
    /// `task`가 nil이 아니면 뜨고, 고르거나 닫으면 nil로 돌아갑니다.
    func repeatingDeleteDialog(
        for task: Binding<AppTask?>,
        onSkip: @escaping (AppTask) -> Void,
        onDeleteAll: @escaping (AppTask) -> Void
    ) -> some View {
        confirmationDialog(
            L.taskEdit.repeatingDeleteTitle,
            isPresented: Binding(
                get: { task.wrappedValue != nil },
                set: { if !$0 { task.wrappedValue = nil } }
            ),
            titleVisibility: .visible,
            presenting: task.wrappedValue
        ) { target in
            Button(L.taskEdit.skipThisOne) { onSkip(target) }
            Button(L.taskEdit.deleteAll, role: .destructive) { onDeleteAll(target) }
            Button(L.cancel, role: .cancel) {}
        } message: { _ in
            Text(L.taskEdit.repeatingDeleteMessage)
        }
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

// MARK: - Task Check Circle
/// 할 일 행 공용 체크 원: 미완료는 테두리, 완료는 틸 채움 + 체크 (루틴·플래너·검색 공통)
struct TaskCheckCircle: View {
    let isCompleted: Bool
    var size: CGFloat = 28
    /// false면 아직 체크할 수 없는 회차 — 점선 테두리로 구분합니다.
    var isEnabled = true

    var body: some View {
        ZStack {
            if isCompleted {
                Circle()
                    .fill(DesignSystem.Colors.tertiary)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundColor(DesignSystem.Colors.onTertiary)
            } else if isEnabled {
                Circle()
                    .strokeBorder(DesignSystem.Colors.outline, lineWidth: 2)
            } else {
                Circle()
                    .strokeBorder(DesignSystem.Colors.outline, style: StrokeStyle(lineWidth: 2, dash: [3, 4]))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Task Edit Sheet
/// 루틴·일정 카드를 누르면 열리는 수정 시트. 카드 안에서 바로 고치던 방식을 대신합니다.
/// 위에서부터 이름 → 날짜·시간·반복·알림 카드 → 저장/삭제 순서로, 한 화면에 초점은 '저장' 하나입니다.
struct TaskEditSheet: View {
    let task: AppTask
    /// 반복 일정에서 '이번만 건너뛰기'를 적용할 날 (플래너는 보고 있는 날, 루틴 탭은 오늘)
    let viewedDate: Date

    @EnvironmentObject private var taskManager: TaskManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var langManager = LocalizationManager.shared

    /// 열 때 한 번 정해 둡니다. 시트가 닫히는 동안 지워진 모델을 다시 읽지 않도록.
    private let isAppointment: Bool

    @State private var title: String
    @State private var hasTime: Bool
    @State private var time: Date
    @State private var day: Date
    @State private var recurrenceRule: String?
    @State private var urgency: Urgency
    /// 반복 일정 삭제 확인을 띄울 대상
    @State private var deleteTarget: AppTask?
    /// 시트가 완전히 닫힌 뒤 지웁니다. 열린 시트가 지워진 모델을 읽지 않게 하려는 것.
    @State private var deletesOnDisappear = false
    /// 알림 설정까지 한 번에 보이도록 크게 열고, 내려서 반만 볼 수도 있습니다.
    @State private var detent: PresentationDetent = .large
    @FocusState private var isTitleFocused: Bool

    /// 반복 메뉴 항목 (nil = 반복 안 함)
    private static let repeatOptions: [String?] = [nil, "weekly", "biweekly", "monthly", "yearly"]

    init(task: AppTask, viewedDate: Date) {
        self.task = task
        self.viewedDate = viewedDate
        isAppointment = task.category == "Appointment"

        let calendar = Calendar.current
        let clock = task.time.flatMap { StoredTaskFormat.hourMinute(from: $0) }
        let storedTime = clock.flatMap {
            calendar.date(bySettingHour: $0.hour, minute: $0.minute, second: 0, of: viewedDate)
        }
        _title = State(initialValue: task.task)
        _hasTime = State(initialValue: storedTime != nil)
        _time = State(initialValue: storedTime ?? Self.nextWholeHour(calendar: calendar))
        _day = State(initialValue: calendar.startOfDay(for: task.date ?? viewedDate))
        _recurrenceRule = State(initialValue: task.recurrenceRule)
        _urgency = State(initialValue: task.urgency)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool { !trimmedTitle.isEmpty }

    private var softAnimation: Animation? {
        reduceMotion ? nil : .timingCurve(0.4, 0, 0.2, 1, duration: 0.3)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 28) {
                // 머리말 + 이름
                VStack(alignment: .leading, spacing: 12) {
                    Text(isAppointment ? L.taskEdit.editAppointment : L.taskEdit.editRoutine)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(DesignSystem.Colors.onSurfaceMeta)
                        .accessibilityAddTraits(.isHeader)

                    titleField
                }

                detailsCard
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .padding(.bottom, 16)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .background(DesignSystem.Colors.background.ignoresSafeArea())
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackground(DesignSystem.Colors.background)
        .onChange(of: hasTime) { _, _ in Haptic.impact(.light) }
        .onChange(of: recurrenceRule) { _, _ in Haptic.impact(.light) }
        .repeatingDeleteDialog(
            for: $deleteTarget,
            onSkip: { target in
                taskManager.skipOccurrence(of: target, on: viewedDate)
                Haptic.impact(.medium)
                dismiss()
            },
            onDeleteAll: { _ in deleteAfterDismiss() }
        )
        .onDisappear {
            guard deletesOnDisappear else { return }
            withAnimation(softAnimation) { taskManager.delete(task: task) }
        }
    }

    // MARK: 이름
    private var titleField: some View {
        TextField(
            "",
            text: $title,
            prompt: Text(L.taskEdit.namePlaceholder).foregroundColor(DesignSystem.Colors.onSurfaceMeta),
            axis: .vertical
        )
        .font(.title2.weight(.semibold))
        .foregroundColor(DesignSystem.Colors.onSurface)
        .tint(DesignSystem.Colors.primary)
        .lineLimit(1...4)
        .focused($isTitleFocused)
        .submitLabel(.done)
        .padding(.bottom, 12)
        // DESIGN.md 'Ghost Border': 입력칸은 아주 옅은 밑줄 하나만
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DesignSystem.Colors.outline.opacity(0.2))
                .frame(height: 1)
        }
        .accessibilityLabel(L.taskEdit.namePlaceholder)
        .onChange(of: title) { _, newValue in
            // 여러 줄 입력칸이라 Return이 줄바꿈이 됩니다. 줄바꿈 대신 입력을 마칩니다.
            guard newValue.contains("\n") else { return }
            title = newValue.replacingOccurrences(of: "\n", with: "")
            isTitleFocused = false
        }
    }

    // MARK: 날짜·시간·반복·알림 카드
    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isAppointment {
                let dateLabel = recurrenceRule == nil ? L.taskEdit.date : L.taskEdit.startDate
                TaskEditRow(icon: "calendar", label: dateLabel) {
                    DatePicker(dateLabel, selection: $day, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .tint(DesignSystem.Colors.primary)
                }
            }

            TaskEditRow(icon: "clock", label: L.taskEdit.time) {
                HStack(spacing: 12) {
                    if hasTime {
                        DatePicker(L.taskEdit.time, selection: $time, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .datePickerStyle(.compact)
                            .tint(DesignSystem.Colors.primary)
                            .transition(.opacity)
                    } else {
                        Text(L.taskEdit.noTime)
                            .font(.body)
                            .foregroundColor(DesignSystem.Colors.onSurfaceMeta)
                            .transition(.opacity)
                    }
                    Toggle(L.taskEdit.setTime, isOn: $hasTime.animation(softAnimation))
                        .labelsHidden()
                        .tint(DesignSystem.Colors.primary)
                        .accessibilityLabel(L.taskEdit.setTime)
                }
            }

            if isAppointment {
                TaskEditRow(icon: "repeat", label: L.taskEdit.repeatTitle) {
                    repeatMenu
                }
            }

            reminderSection
                .padding(.top, 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(DesignSystem.Colors.surfaceContainerLow)
        )
    }

    private var repeatMenu: some View {
        Menu {
            Picker(L.taskEdit.repeatTitle, selection: $recurrenceRule) {
                ForEach(Self.repeatOptions, id: \.self) { rule in
                    Text(repeatLabel(rule)).tag(rule)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(repeatLabel(recurrenceRule))
                    .font(.body)
                    .foregroundColor(DesignSystem.Colors.onSurface)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(DesignSystem.Colors.onSurfaceMeta)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            // 옆 줄의 날짜·시간 선택 칸과 같은 톤의 옅은 바탕
            .background(
                Capsule().fill(DesignSystem.Colors.onSurfaceVariant.opacity(0.08))
            )
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(L.taskEdit.repeatTitle)
        .accessibilityValue(repeatLabel(recurrenceRule))
    }

    private func repeatLabel(_ rule: String?) -> String {
        switch rule {
        case "weekly":   return L.recurrence.weekly
        case "biweekly": return L.taskEdit.repeatBiweekly
        case "monthly":  return L.recurrence.monthly
        case "yearly":   return L.recurrence.yearly
        default:         return L.taskEdit.repeatNever
        }
    }

    private var reminderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "bell")
                    .font(.body.weight(.medium))
                    .foregroundColor(DesignSystem.Colors.primary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(L.taskEdit.reminder)
                    .font(.body)
                    .foregroundColor(DesignSystem.Colors.onSurface)
                    .accessibilityAddTraits(.isHeader)
            }

            HStack(spacing: 10) {
                urgencyChip(.strong)
                urgencyChip(.weak)
            }

            Text(L.taskEdit.reminderHelp)
                .font(.footnote)
                .foregroundColor(DesignSystem.Colors.onSurfaceMeta)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }

    private func urgencyChip(_ value: Urgency) -> some View {
        let isSelected = urgency == value
        let label = value == .strong ? L.voice.urgencyStrong : L.voice.urgencyWeak
        return Button {
            guard urgency != value else { return }
            withAnimation(softAnimation) { urgency = value }
            Haptic.impact(.light)
        } label: {
            // 좁은 화면·큰 글자에서는 아이콘을 빼고 글자만 (줄바꿈 허용)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Image(systemName: value == .strong ? "bolt.fill" : "bolt")
                        .font(.footnote.weight(.semibold))
                    Text(label)
                        .lineLimit(1)
                }
                Text(label)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundColor(isSelected ? DesignSystem.Colors.onPrimary : DesignSystem.Colors.onSurfaceVariant)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(isSelected ? DesignSystem.Colors.primary : DesignSystem.Colors.background)
            )
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: 저장·삭제
    private var footer: some View {
        VStack(spacing: 8) {
            Button(action: save) {
                Text(L.save)
                    .font(.body.weight(.semibold))
                    .foregroundColor(canSave ? DesignSystem.Colors.onPrimary : DesignSystem.Colors.onSurfaceMeta)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(
                        Capsule().fill(canSave
                                       ? AnyShapeStyle(DesignSystem.Gradients.primaryCTA)
                                       : AnyShapeStyle(DesignSystem.Colors.surfaceContainerLow))
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(PressScaleButtonStyle())
            .disabled(!canSave)

            Button(action: requestDelete) {
                Text(L.taskEdit.delete)
                    .font(.body.weight(.semibold))
                    .foregroundColor(DesignSystem.Colors.error)
                    .padding(.horizontal, 24)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleButtonStyle())
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .background(DesignSystem.Colors.background)
    }

    private func save() {
        let trimmed = trimmedTitle
        guard !trimmed.isEmpty else { return }   // 버튼 disabled로 먼저 막고, 한 번 더 방어

        let newTime = storedTimeValue()
        let newDate = storedDateValue()
        let newRule = isAppointment ? recurrenceRule : task.recurrenceRule
        let changed = trimmed != task.task
            || newTime != task.time
            || newDate != task.date
            || newRule != task.recurrenceRule
            || urgency != task.urgency
        guard changed else { dismiss(); return }

        // 바꾸기 전 상태로 되돌리기를 먼저 등록합니다.
        taskManager.setUndoAction(.updated(previous: AppTaskSnapshot(task)), message: L.voice.undoUpdated(trimmed))
        task.task = trimmed
        task.time = newTime
        task.date = newDate
        task.recurrenceRule = newRule
        task.urgency = urgency
        taskManager.update(task: task)
        Haptic.notification(.success)
        dismiss()
    }

    /// 시간을 끄면 nil. 시·분이 그대로면 원래 문자열을 유지하고, 바뀌었을 때만 저장 형식으로 씁니다.
    private func storedTimeValue() -> String? {
        guard hasTime else { return nil }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        if let original = task.time,
           let clock = StoredTaskFormat.hourMinute(from: original),
           clock.hour == parts.hour, clock.minute == parts.minute {
            return original
        }
        return StoredTaskFormat.time.string(from: time)
    }

    /// 일정은 날짜가 꼭 있어야 합니다 (없으면 보고 있던 날). 루틴은 날짜를 건드리지 않습니다.
    private func storedDateValue() -> Date? {
        guard isAppointment else { return task.date }
        if let original = task.date, Calendar.current.isDate(original, inSameDayAs: day) {
            return original
        }
        return Calendar.current.startOfDay(for: day)
    }

    private func requestDelete() {
        Haptic.impact(.medium)
        if task.hasRepeatingSchedule {
            deleteTarget = task
        } else {
            deleteAfterDismiss()
        }
    }

    private func deleteAfterDismiss() {
        deletesOnDisappear = true
        dismiss()
    }

    /// 시간을 새로 켤 때의 기본값: 다음 정각
    private static func nextWholeHour(calendar: Calendar) -> Date {
        let now = Date()
        let hourStart = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        return calendar.date(byAdding: .hour, value: 1, to: hourStart) ?? now
    }
}

/// 수정 시트 카드의 한 줄: 아이콘 + 이름 + 오른쪽 조작. 큰 글자에서는 조작을 아래 줄로 내립니다.
private struct TaskEditRow<Trailing: View>: View {
    let icon: String
    let label: String
    @ViewBuilder let trailing: () -> Trailing
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body.weight(.medium))
                    .foregroundColor(DesignSystem.Colors.primary)
                    .frame(width: 24)
                // 조작마다 같은 이름을 붙였으므로 VoiceOver에서는 한 번만 읽히게 숨깁니다.
                Text(label)
                    .font(.body)
                    .foregroundColor(DesignSystem.Colors.onSurface)
            }
            .accessibilityHidden(true)
            if !stacked { Spacer(minLength: 8) }
            trailing()
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
    }
}
