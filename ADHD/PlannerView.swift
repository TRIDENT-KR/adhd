import SwiftUI
import SwiftData

struct PlannerView: View {
    // MARK: - SwiftData Query
    /// Appointment 전체를 불러와 View에서 날짜 필터링
    @Query(filter: #Predicate<AppTask> { $0.category == "Appointment" },
           sort: \.time)
    private var appointments: [AppTask]

    @EnvironmentObject private var taskManager: TaskManager

    @Binding var activeTab: TabSelection
    @State private var editingTaskId: UUID?
    @State private var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var isCalendarPresented: Bool = false

    private let calendar = Calendar.current

    /// 선택된 날짜와 같은 날의 약속만 반환
    private var filteredAppointments: [AppTask] {
        appointments.filter { task in
            guard let taskDate = task.date else { return false }
            return calendar.isDate(taskDate, inSameDayAs: selectedDate)
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            DesignSystem.Colors.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 40) {

                    // Header
                    HStack {
                        Text(L.plannerTitle)
                            .font(DesignSystem.Typography.displayLg)
                            .foregroundColor(DesignSystem.Colors.primary)
                            .tracking(-0.5)

                        Spacer()

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
                    .padding(.horizontal, 32)

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
                        .frame(minHeight: UIScreen.main.bounds.height * 0.4)
                    } else {
                        LazyVStack(spacing: 32) {
                            ForEach(filteredAppointments) { task in
                                EventCard(task: task, editingTaskId: $editingTaskId)
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
                .navigationTitle("Calendar")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Today") {
                            withAnimation(.spring()) {
                                selectedDate = Calendar.current.startOfDay(for: Date())
                            }
                        }
                        .foregroundColor(DesignSystem.Colors.primary)
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { isCalendarPresented = false }
                            .foregroundColor(DesignSystem.Colors.primary)
                    }
                }
                .background(DesignSystem.Colors.background.ignoresSafeArea())
            }
            // colorScheme follows system setting for dark mode support
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Week Date Selector
    private var weekDateSelector: some View {
        let today = calendar.startOfDay(for: Date())
        let isToday = calendar.isDate(selectedDate, inSameDayAs: today)
        let selectedStart = calendar.startOfDay(for: selectedDate)
        // 오늘 기준 내일부터 6일
        let baseDays = (1...6).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        // 캘린더에서 범위 밖 날짜 선택 시 맨 앞에 삽입 (바로 보이도록)
        let isInRange = isToday || baseDays.contains(where: { calendar.isDate($0, inSameDayAs: selectedStart) })
        let nextDays = isInRange ? baseDays : [selectedStart] + baseDays

        let weekdayFormatter: DateFormatter = {
            let f = DateFormatter(); f.dateFormat = "EEE"; return f
        }()
        let dayFormatter: DateFormatter = {
            let f = DateFormatter(); f.dateFormat = "d"; return f
        }()

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
                        .foregroundColor(isToday ? .white : DesignSystem.Colors.primary)
                    Text(dayFormatter.string(from: today))
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(isToday ? .white : DesignSystem.Colors.primary)
                }
                .frame(width: 56, height: 68)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(isToday ? DesignSystem.Colors.primary : DesignSystem.Colors.primary.opacity(0.08))
                )
            }
            .buttonStyle(NoEffectButtonStyle())

            // 구분선
            Rectangle()
                .fill(DesignSystem.Colors.onSurfaceVariant.opacity(0.12))
                .frame(width: 1, height: 36)
                .padding(.horizontal, 12)

            // 우측: 내일부터 6일 (스크롤)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(nextDays, id: \.self) { date in
                        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)

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
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(isSelected ? DesignSystem.Colors.primaryContainer : Color.clear)
                            )
                        }
                        .buttonStyle(NoEffectButtonStyle())
                    }
                }
                .padding(.trailing, 24)
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

    var isEditing: Bool { editingTaskId == task.id }
    var isDimmed:  Bool { editingTaskId != nil && editingTaskId != task.id }

    var body: some View {
        HStack(spacing: 20) {
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

                TextField("Title", text: $localTaskName)
                    .focused($isTitleFocused)
                    .font(DesignSystem.Typography.bodyMd)
                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                    .submitLabel(.done)
                    .onSubmit { finishEditing() }
            } else {
                Text(task.time ?? "")
                    .font(DesignSystem.Typography.labelSm)
                    .tracking(0.3)
                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.6))
                    .frame(width: 64, alignment: .leading)

                Text(task.task)
                    .font(DesignSystem.Typography.bodyMd)
                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
            }

            Spacer()

            HStack(spacing: 14) {
                if isEditing {
                    Button(action: {
                        withAnimation {
                            taskManager.delete(task: task)
                            editingTaskId = nil
                        }
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }) {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .foregroundColor(.red.opacity(0.6))
                    }
                }

                Button(action: {
                    withAnimation {
                        if isEditing { finishEditing() } else { startEditing() }
                    }
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isTitleFocused = true
                }
            } else {
                isTitleFocused = false
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if isEditing {
                    Spacer()
                    Button("Done") {
                        withAnimation { finishEditing() }
                    }
                }
            }
        }
    }

    private func finishEditing() {
        guard editingTaskId == task.id else { return }
        task.task = localTaskName
        task.time = localTime.isEmpty ? nil : localTime
        taskManager.update(task: task)
        editingTaskId = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func startEditing() {
        editingTaskId = task.id
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
