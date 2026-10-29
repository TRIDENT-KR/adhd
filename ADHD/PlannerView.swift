import SwiftUI
import SwiftData
import Combine

struct PlannerView: View {
    // MARK: - SwiftData Query
    /// Appointment 전체를 불러와 View에서 날짜 필터링
    @Query(filter: #Predicate<AppTask> { $0.category == "Appointment" },
           sort: \.time)
    private var appointments: [AppTask]

    @EnvironmentObject private var taskManager: TaskManager
    @EnvironmentObject private var authManager: AuthManager
    @ObservedObject var langManager = LocalizationManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Binding var activeTab: TabSelection
    /// 수정 시트로 연 일정 (카드를 누르면 열림)
    @State private var editingTask: AppTask?
    /// 밀어서 지우려는 반복 일정 (건너뛰기/전체 삭제를 묻는 중)
    @State private var repeatingDeleteTarget: AppTask?
    @State private var selectedDate: Date
    /// 자정이 지났는지 비교할 '지난 오늘'
    @State private var lastKnownToday: Date
    @State private var showQuickAdd = false
    @State private var isCalendarPresented: Bool = false
    @State private var showSearch: Bool = false

    private let calendar = Calendar.current

    /// - Parameter initialDate: 처음 만들 때 보여 줄 날 (검색에서 고른 일정). nil이면 오늘.
    init(activeTab: Binding<TabSelection>, initialDate: Date? = nil) {
        _activeTab = activeTab
        let today = Calendar.current.startOfDay(for: Date())
        _selectedDate = State(initialValue: initialDate.map { Calendar.current.startOfDay(for: $0) } ?? today)
        _lastKnownToday = State(initialValue: today)
    }

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE"; return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d"; return f
    }()

    @State private var isReordering = false

    /// 선택된 날짜와 같은 날의 약속만 반환 (반복 일정 포함), 사용자 정렬 > 시간순
    private var filteredAppointments: [AppTask] {
        appointments
            .filter { $0.occursOn(selectedDate) }
            .sorted { a, b in
                if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
                return a.sortableTime < b.sortableTime
            }
    }

    /// 특정 날짜에 이벤트가 있는지 확인 (배지 표시용)
    private func hasEvents(on date: Date) -> Bool {
        appointments.contains { $0.occursOn(date) }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            DesignSystem.Colors.background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {

                    // 제목 + 더보기(달력·검색·순서 변경) + 추가
                    ScreenHeader(title: "Planner", addLabel: L.quickAdd.title, onAdd: { showQuickAdd = true }) {
                        Button(action: { isCalendarPresented.toggle() }) {
                            Label(L.t("Open calendar", "달력 열기", "カレンダーを開く"), systemImage: "calendar")
                        }
                        Button(action: { showSearch = true }) {
                            Label(L.t("Search tasks", "일정 검색", "タスクを検索"), systemImage: "magnifyingglass")
                        }
                        Button(action: toggleReordering) {
                            Label(L.t("Reorder tasks", "일정 순서 변경", "タスクを並べ替える"), systemImage: "arrow.up.arrow.down")
                        }
                    }
                    .padding(.top, 16)
                    .padding(.horizontal, 20)

                    // 요일 선택 바: 오늘 | 나머지 요일
                    weekDateSelector

                    if isReordering {
                        HStack {
                            Spacer()
                            Button(action: toggleReordering) {
                                Text(L.t("Done", "완료", "完了"))
                                    .font(.subheadline.weight(.bold))
                                    .foregroundColor(DesignSystem.Colors.tertiary)
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .accessibilityLabel(L.t("Finish reordering", "순서 변경 완료", "並べ替えを完了"))
                        }
                        .padding(.horizontal, 20)
                    }

                    // 타임라인
                    if filteredAppointments.isEmpty {
                        GeometryReader { geo in
                            VStack(spacing: 20) {
                                Image(systemName: authManager.accessState.isGuest ? "plus.circle" : "mic.fill")
                                    .font(.system(size: 48))
                                    .foregroundColor(DesignSystem.Colors.primary.opacity(0.5))
                                    .accessibilityHidden(true)
                                Text(L.plannerEmpty)
                                    .font(DesignSystem.Typography.bodyMd)
                                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.7))
                            }
                            .frame(width: geo.size.width, height: geo.size.height)
                            .onTapGesture {
                                if authManager.accessState.isGuest { showQuickAdd = true }
                                else if reduceMotion { activeTab = .voice }
                                else { withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.3)) { activeTab = .voice } }
                            }
                            .accessibilityLabel(authManager.accessState.isGuest
                                ? L.t("No tasks yet. Add a task", "아직 일정이 없어요. 일정 추가", "予定はまだありません。タスクを追加")
                                : L.t("No tasks yet. Add with voice", "아직 일정이 없어요. 음성으로 추가", "予定はまだありません。音声で追加"))
                            .accessibilityAddTraits(.isButton)
                        }
                        .frame(minHeight: ((UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.height ?? 800) * 0.4)
                    } else if isReordering {
                        // 정렬 모드: 부드러운 드래그 리오더
                        SmoothTaskReorderList(tasks: filteredAppointments, taskManager: taskManager)
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(filteredAppointments) { task in
                                let isRepeating = task.hasRepeatingSchedule
                                EventCard(task: task, displayedDate: selectedDate, onEdit: { editingTask = task })
                                    .swipeToDelete(confirmsFirst: isRepeating) {
                                        // 반복 일정은 시리즈 전체를 조용히 지우지 않고 먼저 묻습니다.
                                        if isRepeating {
                                            repeatingDeleteTarget = task
                                        } else {
                                            withAnimation { taskManager.delete(task: task) }
                                            Haptic.impact(.medium)
                                        }
                                    }
                            }
                        }
                    }

                    Spacer(minLength: 140)
                }
            }
        }
        .sheet(isPresented: $isCalendarPresented) {
            NavigationView {
                VStack {
                    VStack {
                        DatePicker(
                            "Select Date",
                            selection: $selectedDate,
                            displayedComponents: [.date]
                        )
                        .datePickerStyle(.graphical)
                        .tint(DesignSystem.Colors.primary)
                    }
                    .padding()
                    .background(DesignSystem.Colors.surfaceContainerLow)
                    .cornerRadius(24)
                    .padding()

                    Spacer()
                }
                .navigationTitle(Text(verbatim: "Calendar"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(L.calendarToday) {
                            withAnimation(.spring()) {
                                selectedDate = Calendar.current.startOfDay(for: Date())
                            }
                        }
                        .foregroundColor(DesignSystem.Colors.primary)
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(L.settings.done) { isCalendarPresented = false }
                            .foregroundColor(DesignSystem.Colors.primary)
                    }
                }
                .background(DesignSystem.Colors.background.ignoresSafeArea())
            }
            // colorScheme follows system setting for dark mode support
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showQuickAdd) {
            QuickAddSheet(mode: .appointment(selectedDate))
        }
        .sheet(isPresented: $showSearch) {
            SearchView()
        }
        .sheet(item: $editingTask) { task in
            TaskEditSheet(task: task, viewedDate: selectedDate)
        }
        .repeatingDeleteDialog(
            for: $repeatingDeleteTarget,
            onSkip: { task in
                withAnimation { taskManager.skipOccurrence(of: task, on: selectedDate) }
                Haptic.impact(.medium)
            },
            onDeleteAll: { task in
                withAnimation { taskManager.delete(task: task) }
                Haptic.impact(.medium)
            }
        )
        // 검색 결과에서 일정을 고르면 그 날로 이동합니다 (어느 탭에서 검색했든).
        .onReceive(NotificationCenter.default.publisher(for: .plannerJumpToDate)) { notification in
            guard let date = notification.object as? Date else { return }
            selectedDate = calendar.startOfDay(for: date)
        }
        // 앱을 켜 둔 채 자정이 지나면: '오늘'을 보고 있었다면 새 오늘로 옮깁니다.
        .onReceive(
            NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: DispatchQueue.main)
        ) { _ in
            let newToday = calendar.startOfDay(for: Date())
            if calendar.isDate(selectedDate, inSameDayAs: lastKnownToday) {
                selectedDate = newToday
            }
            lastKnownToday = newToday
        }
    }

    /// 선택한 날의 달 (올해가 아니면 연도까지): "October", "10월", "2027년 10월"
    private var monthLabel: String {
        let locale = Locale(identifier: langManager.currentLanguage.localeIdentifier)
        let isThisYear = calendar.isDate(selectedDate, equalTo: Date(), toGranularity: .year)
        let style = isThisYear
            ? Date.FormatStyle().month(.wide)
            : Date.FormatStyle().year().month(.wide)
        return selectedDate.formatted(style.locale(locale))
    }

    /// 날짜 버튼 VoiceOver 이름: 전체 날짜 + 오늘 + 일정 있음
    private func dateAccessibilityLabel(_ date: Date, isToday: Bool) -> String {
        let locale = Locale(identifier: langManager.currentLanguage.localeIdentifier)
        var label = date.formatted(Date.FormatStyle(date: .complete, time: .omitted).locale(locale))
        if isToday { label += L.t(", Today", ", 오늘", "、今日") }
        if hasEvents(on: date) { label += L.t(", has events", ", 일정 있음", "、予定あり") }
        return label
    }

    // MARK: - Week Date Selector
    @State private var scrollTarget: Date?

    private var weekDateSelector: some View {
        let today = calendar.startOfDay(for: Date())
        let selected = calendar.startOfDay(for: selectedDate)
        let isTodaySelected = calendar.isDate(selected, inSameDayAs: today)

        // 우측: 선택 날짜 기준 -7 ~ +7 (15일), 오늘과 겹치면 제외
        let rightDays: [Date] = (-7...7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: selected) else { return nil }
            let d = calendar.startOfDay(for: date)
            // 오늘은 좌측에 고정이므로 제외
            return calendar.isDate(d, inSameDayAs: today) ? nil : d
        }

        let weekdayFormatter = Self.weekdayFormatter
        let dayFormatter = Self.dayFormatter
        weekdayFormatter.locale = Locale(identifier: langManager.currentLanguage.rawValue)
        dayFormatter.locale = Locale(identifier: langManager.currentLanguage.rawValue)

        return VStack(alignment: .leading, spacing: 10) {
            // 선택한 날의 달 — 날짜 숫자만으로는 몇 월인지 알 수 없어서
            Text(monthLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(DesignSystem.Colors.onSurfaceMeta)
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 0) {
                // 좌측: 오늘 고정
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        selectedDate = today
                    }
                }) {
                    VStack(spacing: 4) {
                        Text(weekdayFormatter.string(from: today))
                            .font(.caption.weight(.bold))
                            .foregroundColor(isTodaySelected ? DesignSystem.Colors.onPrimary : DesignSystem.Colors.primary)
                        Text(dayFormatter.string(from: today))
                            .font(.title2.weight(.bold))
                            .foregroundColor(isTodaySelected ? DesignSystem.Colors.onPrimary : DesignSystem.Colors.primary)
                            .minimumScaleFactor(0.8)
                    }
                    .padding(.vertical, 10)
                    .frame(minWidth: 56, minHeight: 68)
                    .overlay(alignment: .bottom) {
                        if hasEvents(on: today) {
                            Circle()
                                .fill(isTodaySelected ? DesignSystem.Colors.onPrimary : DesignSystem.Colors.primary)
                                .frame(width: 5, height: 5)
                                .offset(y: -6)
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(isTodaySelected ? DesignSystem.Colors.primary : DesignSystem.Colors.primary.opacity(0.08))
                    )
                }
                .buttonStyle(NoEffectButtonStyle())
                .accessibilityLabel(dateAccessibilityLabel(today, isToday: true))
                .accessibilityAddTraits(isTodaySelected ? .isSelected : [])

                // 오늘과 나머지 요일 사이는 선 대신 여백으로 나눕니다 (DESIGN.md No-Line)
                Spacer().frame(width: 16)

                // 우측: 선택 날짜 ±7일 스크롤 뷰
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(rightDays, id: \.self) { date in
                                let isSelected = calendar.isDate(date, inSameDayAs: selected)

                                Button(action: {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                        selectedDate = date
                                    }
                                }) {
                                    VStack(spacing: 4) {
                                        Text(weekdayFormatter.string(from: date))
                                            .font(.caption2.weight(.medium))
                                            .foregroundColor(isSelected ? DesignSystem.Colors.onPrimary : DesignSystem.Colors.onSurfaceVariant.opacity(0.7))
                                        Text(dayFormatter.string(from: date))
                                            .font(.title3.weight(isSelected ? .bold : .semibold))
                                            .foregroundColor(isSelected ? DesignSystem.Colors.onPrimary : DesignSystem.Colors.onSurfaceVariant)
                                            .minimumScaleFactor(0.8)
                                    }
                                    .padding(.vertical, 10)
                                    .frame(minWidth: 50, minHeight: 64)
                                    .overlay(alignment: .bottom) {
                                        if hasEvents(on: date) {
                                            Circle()
                                                .fill(isSelected ? DesignSystem.Colors.onPrimary : DesignSystem.Colors.primaryContainer)
                                                .frame(width: 5, height: 5)
                                                .offset(y: -6)
                                        }
                                    }
                                    .background(
                                        RoundedRectangle(cornerRadius: 14)
                                            .fill(isSelected ? DesignSystem.Colors.primaryContainer : Color.clear)
                                    )
                                }
                                .buttonStyle(NoEffectButtonStyle())
                                .accessibilityLabel(dateAccessibilityLabel(date, isToday: false))
                                .accessibilityAddTraits(isSelected ? .isSelected : [])
                                .id(date)
                            }
                        }
                        .padding(.trailing, 24)
                    }
                    .onChange(of: selectedDate) { _, newDate in
                        let target = calendar.startOfDay(for: newDate)
                        if calendar.isDate(target, inSameDayAs: today) {
                            // 오늘 선택 → 내일(오늘 다음날)을 최좌측에 배치
                            if let tomorrow = rightDays.first(where: { $0 > today }) {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    proxy.scrollTo(tomorrow, anchor: .leading)
                                }
                            }
                        } else {
                            // 다른 날짜 선택 → 해당 날짜를 최좌측에 배치
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(target, anchor: .leading)
                            }
                        }
                    }
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            if isTodaySelected {
                                if let tomorrow = rightDays.first(where: { $0 > today }) {
                                    proxy.scrollTo(tomorrow, anchor: .leading)
                                }
                            } else {
                                proxy.scrollTo(selected, anchor: .leading)
                            }
                        }
                    }
                }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.leading, 24)
    }
}

extension PlannerView {
    fileprivate func toggleReordering() {
        let anim: Animation? = reduceMotion ? .none : .timingCurve(0.4, 0, 0.2, 1, duration: 0.3)
        withAnimation(anim) {
            isReordering.toggle()
        }
    }
}

// MARK: - Event Card Component
struct EventCard: View {
    var task: AppTask
    /// 플래너에서 보고 있는 날 (반복 일정의 체크 가능 여부 판단용)
    var displayedDate: Date
    /// 카드를 누르면 수정 시트를 엽니다.
    var onEdit: () -> Void

    @EnvironmentObject private var taskManager: TaskManager
    @State private var isExpanded = false
    @State private var isTruncated = false
    @State private var cachedCategoryIcon: String = "calendar"

    /// 반복 일정을 오늘이 아닌 날에 보고 있는지. 완료 표시는 시리즈에 하나뿐이라
    /// 다른 날 회차에서 체크하면 오늘 회차가 완료돼 버리므로 그날이 올 때까지 막아 둡니다.
    private var isOtherDayOccurrence: Bool {
        task.hasRepeatingSchedule && !Calendar.current.isDateInToday(displayedDate)
    }

    /// 이 카드에서 보여 줄 완료 상태 (다른 날 회차는 항상 미완료)
    private var showsCompleted: Bool {
        task.isCompleted && !isOtherDayOccurrence
    }

    var body: some View {
        // [체크박스 탭 → 완료토글]  [내용 탭 → 수정 시트]
        HStack(alignment: .top, spacing: 12) {

            // 체크박스
            Button(action: {
                withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.3)) {
                    taskManager.toggleCompletion(of: task)
                }
                Haptic.impact(.medium)
            }) {
                TaskCheckCircle(isCompleted: showsCompleted, isEnabled: !isOtherDayOccurrence)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .disabled(isOtherDayOccurrence)
            .accessibilityLabel("\(task.task), \(showsCompleted ? L.t("completed", "완료", "完了") : L.t("not completed", "미완료", "未完了"))")
            .accessibilityHint(isOtherDayOccurrence
                ? L.taskEdit.checkOffOnTheDay
                : L.t("Double tap to toggle completion", "완료 상태를 바꾸려면 이중 탭하세요", "完了状態を切り替えるにはダブルタップ"))

            // 아이콘 + 제목 + 메타 (탭 → 수정 시트)
            VStack(alignment: .leading, spacing: 0) {

                // 1행: 아이콘 + 제목
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: cachedCategoryIcon)
                        .font(.footnote)
                        .dynamicTypeSize(...DynamicTypeSize.large)
                        .foregroundColor(showsCompleted ? DesignSystem.Colors.onSurfaceMeta : DesignSystem.Colors.primary)
                        .frame(width: 18)
                        .padding(.top, 3)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.task)
                            .font(.body.weight(.semibold))
                            .strikethrough(showsCompleted, color: DesignSystem.Colors.onSurfaceMeta)
                            .foregroundColor(showsCompleted ? DesignSystem.Colors.onSurfaceMeta : DesignSystem.Colors.onSurface)
                            .lineLimit(isExpanded ? nil : 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                GeometryReader { constrainedGeo in
                                    Text(task.task)
                                        .font(.body.weight(.semibold))
                                        .fixedSize(horizontal: false, vertical: true)
                                        .hidden()
                                        .background(
                                            GeometryReader { idealGeo in
                                                Color.clear.onAppear {
                                                    isTruncated = idealGeo.size.height > constrainedGeo.size.height + 2
                                                }
                                            }
                                        )
                                }
                            )

                        if isTruncated || isExpanded {
                            Button(action: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    isExpanded.toggle()
                                }
                            }) {
                                Image(systemName: isExpanded ? "chevron.compact.up" : "chevron.compact.down")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(DesignSystem.Colors.onSurfaceMeta)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 16)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(NoEffectButtonStyle())
                        }
                    }
                }

                // 2행: 시간 + 반복 + 알림 (아이콘 좌측 정렬)
                HStack(spacing: 5) {
                    if let time = task.time, !time.isEmpty {
                        Text(StoredTaskFormat.displayTime(time))
                            .font(.subheadline)
                            .foregroundColor(DesignSystem.Colors.onSurfaceMeta)
                    }
                    if task.isRecurring {
                        Image(systemName: "repeat")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(DesignSystem.Colors.onSurfaceMeta)
                    }
                    Image(systemName: task.urgency == .strong ? "bolt.fill" : "bolt")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(task.urgency == .strong ? DesignSystem.Colors.primary : DesignSystem.Colors.onSurfaceMeta)
                }
                .padding(.top, 4)
                .accessibilityLabel(task.urgency == .strong ? L.voice.urgencyStrong : L.voice.urgencyWeak)
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
            cachedCategoryIcon = CategoryIconResolver.resolveIcon(for: task.task, category: task.category, urgency: task.urgency)
        }
        // 수정 시트에서 이름·알림 강도를 바꾸면 아이콘도 다시 고릅니다.
        .onChange(of: task.task) { _, newName in
            cachedCategoryIcon = CategoryIconResolver.resolveIcon(for: newName, category: task.category, urgency: task.urgency)
        }
        .onChange(of: task.urgency) { _, newUrgency in
            cachedCategoryIcon = CategoryIconResolver.resolveIcon(for: task.task, category: task.category, urgency: newUrgency)
        }
    }
}

// MARK: - NoEffectButtonStyle
struct NoEffectButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

// MARK: - Preview
struct PlannerView_Previews: PreviewProvider {
    static var previews: some View {
        PlannerView(activeTab: .constant(.planner))
            .environmentObject(TaskManager())
            .environmentObject(AuthManager())
    }
}
