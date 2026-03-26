import SwiftUI
import SwiftData

struct PlannerView: View {
    // MARK: - SwiftData Query
    /// Appointment 전체를 불러와 View에서 날짜 필터링
    @Query(filter: #Predicate<AppTask> { $0.category == "Appointment" },
           sort: \.time)
    private var appointments: [AppTask]

    @EnvironmentObject private var taskManager: TaskManager

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
                        Text("My Planner")
                            .font(DesignSystem.Typography.displayLg)
                            .foregroundColor(DesignSystem.Colors.primary)
                            .tracking(-0.5)

                        Spacer()

                        Button(action: { isCalendarPresented.toggle() }) {
                            Image(systemName: "calendar")
                                .font(.system(size: 24, weight: .light))
                                .foregroundColor(DesignSystem.Colors.primary)
                                .padding(12)
                                .background(Circle().fill(DesignSystem.Colors.primaryContainer))
                                .contentShape(Circle())
                        }
                        .buttonStyle(NoEffectButtonStyle())
                    }
                    .padding(.top, 16)
                    .padding(.horizontal, 32)

                    // 7일 날짜 선택 스크롤
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 20) {
                            let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: selectedDate)?.start ?? selectedDate
                            let days = (0...6).compactMap { calendar.date(byAdding: .day, value: $0, to: startOfWeek) }

                            let weekdayFormatter: DateFormatter = {
                                let f = DateFormatter(); f.dateFormat = "E"; return f
                            }()
                            let dayFormatter: DateFormatter = {
                                let f = DateFormatter(); f.dateFormat = "d"; return f
                            }()

                            ForEach(days, id: \.self) { date in
                                let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
                                Button(action: {
                                    withAnimation(.spring()) { selectedDate = date }
                                }) {
                                    VStack(spacing: 6) {
                                        Text(weekdayFormatter.string(from: date).prefix(1))
                                            .font(DesignSystem.Typography.bodyMd)
                                            .foregroundColor(isSelected ? .white : DesignSystem.Colors.onSurfaceVariant)
                                        Text(dayFormatter.string(from: date))
                                            .font(DesignSystem.Typography.titleSm)
                                            .foregroundColor(isSelected ? .white : DesignSystem.Colors.onSurfaceVariant.opacity(0.6))
                                    }
                                    .padding(.vertical, 16)
                                    .padding(.horizontal, 16)
                                    .frame(minWidth: 60)
                                    .background(isSelected ? Capsule().fill(DesignSystem.Colors.primaryContainer) : Capsule().fill(Color.clear))
                                    .contentShape(Capsule())
                                }
                                .buttonStyle(NoEffectButtonStyle())
                            }
                        }
                        .padding(.horizontal, 32)
                    }

                    // 타임라인
                    if filteredAppointments.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "circle.dotted")
                                .font(.system(size: 40))
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.2))
                            Text("No plans for this date.")
                                .font(DesignSystem.Typography.bodyMd)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.6))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else {
                        LazyVStack(spacing: 24) {
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
        PlannerView()
            .environmentObject(TaskManager())
    }
}
