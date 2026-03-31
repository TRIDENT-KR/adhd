import SwiftUI
import SwiftData

struct PlannerView: View {
    // MARK: - SwiftData Query
    /// Appointment 전체를 불러와 View에서 날짜 필터링
    @Query(filter: #Predicate<AppTask> { $0.category == "Appointment" },
           sort: \.time)
    private var appointments: [AppTask]

    @EnvironmentObject private var taskManager: TaskManager
    @ObservedObject var langManager = LocalizationManager.shared


    @Binding var activeTab: TabSelection
    @State private var editingTaskId: UUID?
    @State private var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var isCalendarPresented: Bool = false
    @State private var showSearch: Bool = false

    private let calendar = Calendar.current

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
                VStack(alignment: .leading, spacing: 40) {

                    // Header
                    HStack {
                        Text(verbatim: "Planner")
                            .font(DesignSystem.Typography.displayLg)
                            .foregroundColor(DesignSystem.Colors.primary)
                            .tracking(-0.5)

                        Spacer()

                        Button(action: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                isReordering.toggle()
                                if isReordering { editingTaskId = nil }
                            }
                        }) {
                            Image(systemName: isReordering ? "checkmark.circle.fill" : "arrow.up.arrow.down")
                                .font(.system(size: 18, weight: .light))
                                .foregroundColor(isReordering ? DesignSystem.Colors.tertiary : DesignSystem.Colors.onSurfaceVariant.opacity(0.4))
                                .padding(8)
                                .contentShape(Circle())
                        }
                        .buttonStyle(NoEffectButtonStyle())

                        Button(action: { showSearch = true }) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 20, weight: .light))
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.4))
                                .padding(8)
                                .contentShape(Circle())
                        }
                        .buttonStyle(NoEffectButtonStyle())

                        Button(action: { isCalendarPresented.toggle() }) {
                            Image(systemName: "calendar")
                                .font(.system(size: 24, weight: .light))
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.4))
                                .padding(12)
                                .contentShape(Circle())
                        }
                        .buttonStyle(NoEffectButtonStyle())
                    }
                    .padding(.top, 16)
                    .padding(.leading, 32)
                    .padding(.trailing, 20)

                    // 요일 선택 바: 오늘 | 나머지 요일
                    weekDateSelector

                    // 타임라인
                    if filteredAppointments.isEmpty {
                        GeometryReader { geo in
                            VStack(spacing: 20) {
                                Image(systemName: "mic.fill")
                                    .font(.system(size: 48))
                                    .foregroundColor(DesignSystem.Colors.primary.opacity(0.3))
                                Text(L.plannerEmpty)
                                    .font(DesignSystem.Typography.bodyMd)
                                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.6))
                            }
                            .frame(width: geo.size.width, height: geo.size.height)
                            .onTapGesture {
                                withAnimation(.spring()) { activeTab = .voice }
                            }
                        }
                        .frame(minHeight: ((UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.height ?? 800) * 0.4)
                    } else if isReordering {
                        LazyVStack(spacing: 16) {
                            ForEach(filteredAppointments) { task in
                                ReorderRow(task: task, allTasks: filteredAppointments, taskManager: taskManager)
                            }
                        }
                    } else {
                        LazyVStack(spacing: 32) {
                            ForEach(filteredAppointments) { task in
                                EventCard(task: task, editingTaskId: $editingTaskId)
                                    .swipeToDelete {
                                        withAnimation { taskManager.delete(task: task) }
                                        Haptic.impact(.medium)
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
        .sheet(isPresented: $showSearch) {
            SearchView { date in
                // 검색 결과에서 Appointment 선택 시 해당 날짜로 이동
                selectedDate = Calendar.current.startOfDay(for: date)
            }
        }
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

        return HStack(spacing: 0) {
            // 좌측: 오늘 고정
            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    selectedDate = today
                }
            }) {
                VStack(spacing: 4) {
                    Text(weekdayFormatter.string(from: today))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(isTodaySelected ? .white : DesignSystem.Colors.primary)
                    Text(dayFormatter.string(from: today))
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(isTodaySelected ? .white : DesignSystem.Colors.primary)
                }
                .frame(width: 56, height: 68)
                .overlay(alignment: .bottom) {
                    if hasEvents(on: today) {
                        Circle()
                            .fill(isTodaySelected ? .white : DesignSystem.Colors.primary)
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

            // 구분선
            Rectangle()
                .fill(DesignSystem.Colors.onSurfaceVariant.opacity(0.12))
                .frame(width: 1, height: 36)
                .padding(.horizontal, 12)

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
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(isSelected ? .white : DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                                    Text(dayFormatter.string(from: date))
                                        .font(.system(size: 22, weight: isSelected ? .bold : .semibold))
                                        .foregroundColor(isSelected ? .white : DesignSystem.Colors.onSurfaceVariant)
                                }
                                .frame(width: 50, height: 64)
                                .overlay(alignment: .bottom) {
                                    if hasEvents(on: date) {
                                        Circle()
                                            .fill(isSelected ? .white : DesignSystem.Colors.primaryContainer)
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
                            .id(date)
                        }
                    }
                    .padding(.trailing, 24)
                }
                .onChange(of: selectedDate) { _, newDate in
                    let target = calendar.startOfDay(for: newDate)
                    // 오늘 선택 시에도 스크롤 위치 리셋 (오늘 다음날로)
                    if calendar.isDate(target, inSameDayAs: today) {
                        if let firstDay = rightDays.first {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(firstDay, anchor: .leading)
                            }
                        }
                    } else {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(target, anchor: .center)
                        }
                    }
                }
                .onAppear {
                    // 초기 로드 시 선택 날짜가 중앙에 오도록
                    if !isTodaySelected {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            proxy.scrollTo(selected, anchor: .center)
                        }
                    }
                }
            }
        }
        .padding(.leading, 24)
    }
}

// MARK: - Event Card Component
struct EventCard: View {
    var task: AppTask
    @Binding var editingTaskId: UUID?

    @EnvironmentObject private var taskManager: TaskManager
    @FocusState private var isTitleFocused: Bool
    @State private var showingTimePicker = false
    @State private var localTaskName: String = ""
    @State private var localTime: String     = ""
    @State private var localUrgency: Urgency  = .weak

    var isEditing: Bool { editingTaskId == task.id }
    var isDimmed:  Bool { editingTaskId != nil && editingTaskId != task.id }

    var body: some View {
        HStack(spacing: 20) {
            // Completion checkbox (#25)
            if !isEditing {
                Button(action: {
                    withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.3)) {
                        taskManager.toggleCompletion(of: task)
                    }
                    Haptic.impact(.medium)
                }) {
                    ZStack {
                        Circle()
                            .stroke(DesignSystem.Colors.onSurfaceVariant.opacity(0.3), lineWidth: 1.5)
                            .frame(width: 28, height: 28)
                        if task.isCompleted {
                            Circle()
                                .fill(DesignSystem.Colors.tertiary)
                                .frame(width: 28, height: 28)
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                }
            }

            if isEditing {
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

                // urgency 토글
                Button(action: {
                    localUrgency = (localUrgency == .weak) ? .strong : .weak
                    Haptic.impact(.light)
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: localUrgency == .strong ? "bolt.fill" : "bolt")
                            .font(.system(size: 12, weight: .semibold))
                        Text(localUrgency == .strong ? "Strong" : "Weak")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(localUrgency == .strong ? .orange : DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background((localUrgency == .strong ? Color.orange : DesignSystem.Colors.onSurfaceVariant).opacity(0.12))
                    .cornerRadius(6)
                }
                .buttonStyle(NoEffectButtonStyle())

                TextField("Title", text: $localTaskName)
                    .focused($isTitleFocused)
                    .font(DesignSystem.Typography.bodyMd)
                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                    .submitLabel(.done)
                    .onSubmit { finishEditing() }
            } else {
                HStack(spacing: 4) {
                    Text(task.time ?? "시간 미정")
                        .font(DesignSystem.Typography.labelSm)
                        .tracking(0.3)
                        .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(task.isCompleted ? 0.3 : 0.6))
                    if task.isRecurring {
                        Image(systemName: "repeat")
                            .font(.system(size: 10))
                            .foregroundColor(DesignSystem.Colors.primary.opacity(0.5))
                    }
                }
                .frame(width: task.isRecurring ? 80 : 64, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(task.task)
                        .font(DesignSystem.Typography.bodyMd)
                        .strikethrough(task.isCompleted, color: DesignSystem.Colors.onSurfaceVariant)
                        .foregroundColor(task.isCompleted
                            ? DesignSystem.Colors.onSurfaceVariant.opacity(0.4)
                            : DesignSystem.Colors.onSurfaceVariant)
                    if let label = task.recurrenceLabel {
                        Text(label)
                            .font(.system(size: 11))
                            .foregroundColor(DesignSystem.Colors.primary.opacity(0.5))
                    }
                }
            }

            Spacer()

            HStack(spacing: 14) {
                if !isEditing && task.urgency == .strong {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.orange.opacity(0.7))
                }
                if isEditing {
                    Button(action: {
                        withAnimation {
                            taskManager.delete(task: task)
                            editingTaskId = nil
                        }
                        Haptic.impact(.medium)
                    }) {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .foregroundColor(.red.opacity(0.6))
                    }
                }

                Button(action: {
                    if isEditing { finishEditing() } else { withAnimation { startEditing() } }
                }) {
                    Image(systemName: isEditing ? "checkmark" : "pencil")
                        .font(.system(size: 16))
                }
                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.3))
            }
        }
        .padding(24)
        .background(DesignSystem.Colors.primary.opacity(0.05))
        .cornerRadius(24)
        .padding(.horizontal, 32)
        .opacity(isDimmed ? 0.3 : 1.0)
        .onAppear {
            localTaskName = task.task
            localTime     = task.time ?? ""
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
        editingTaskId = nil
        Haptic.impact(.light)
    }

    private func startEditing() {
        localUrgency  = task.urgency
        editingTaskId = task.id
        Haptic.impact(.medium)
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
    }
}
