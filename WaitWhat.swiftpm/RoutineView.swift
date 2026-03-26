import SwiftUI
import SwiftData

struct RoutineView: View {
    // MARK: - SwiftData Queries
    /// category == "Routine" 데이터만 필터링
    @Query(filter: #Predicate<AppTask> { $0.category == "Routine" },
           sort: \.time)
    private var routines: [AppTask]

    /// category == "Appointment" 데이터만 필터링
    @Query(filter: #Predicate<AppTask> { $0.category == "Appointment" },
           sort: \.time)
    private var appointments: [AppTask]

    @EnvironmentObject private var taskManager: TaskManager
    @Environment(\.modelContext) private var modelContext

    @State private var editingTaskId: UUID?

    var body: some View {
        ZStack(alignment: .bottom) {
            DesignSystem.Colors.background
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 48) {

                    // 제목
                    Text("My Routines")
                        .font(DesignSystem.Typography.displayLg)
                        .foregroundColor(DesignSystem.Colors.primary)
                        .tracking(-0.5)
                        .padding(.top, 16)
                        .padding(.horizontal, 32)

                    // Daily Routines 섹션
                    VStack(alignment: .leading, spacing: 32) {
                        Text("Daily Routines")
                            .font(DesignSystem.Typography.titleSm)
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                            .padding(.horizontal, 32)

                        LazyVStack(spacing: 32) {
                            // 미완료 먼저
                            ForEach(routines.filter { !$0.isCompleted }) { task in
                                TaskRow(task: task, editingTaskId: $editingTaskId)
                            }
                            // 완료 항목
                            ForEach(routines.filter { $0.isCompleted }) { task in
                                TaskRow(task: task, editingTaskId: $editingTaskId)
                            }
                        }
                    }

                    // Today's Tasks 섹션
                    VStack(alignment: .leading, spacing: 32) {
                        Text("Today's Tasks")
                            .font(DesignSystem.Typography.titleSm)
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                            .padding(.horizontal, 32)

                        LazyVStack(spacing: 32) {
                            ForEach(appointments.filter { !$0.isCompleted }) { task in
                                TaskRow(task: task, editingTaskId: $editingTaskId)
                            }
                            ForEach(appointments.filter { $0.isCompleted }) { task in
                                TaskRow(task: task, editingTaskId: $editingTaskId)
                            }
                        }
                    }

                    Spacer(minLength: 140)
                }
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }
}

// MARK: - Task Row Component
struct TaskRow: View {
    /// AppTask는 @Model 참조 타입이므로 직접 참조하여 수정합니다.
    var task: AppTask
    @Binding var editingTaskId: UUID?

    @EnvironmentObject private var taskManager: TaskManager
    @Environment(\.modelContext) private var modelContext

    @FocusState private var isTitleFocused: Bool
    @State private var showingTimePicker = false
    @State private var localTaskName: String = ""
    @State private var localTime: String     = ""

    var isEditing: Bool { editingTaskId == task.id }
    var isDimmed:  Bool { editingTaskId != nil && editingTaskId != task.id }

    var body: some View {
        HStack(spacing: 20) {
            // 체크박스
            Button(action: {
                withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.3)) {
                    taskManager.toggleCompletion(of: task)
                }
            }) {
                ZStack {
                    Circle()
                        .stroke(DesignSystem.Colors.onSurfaceVariant.opacity(0.3), lineWidth: 1.5)
                        .frame(width: 32, height: 32)

                    if task.isCompleted {
                        Circle()
                            .fill(Color(hex: "#006A63"))
                            .frame(width: 32, height: 32)
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
            }
            .disabled(isEditing)

            // 텍스트 / 편집 영역
            VStack(alignment: .leading, spacing: 6) {
                if isEditing {
                    TextField("Task", text: $localTaskName)
                        .focused($isTitleFocused)
                        .font(DesignSystem.Typography.bodyMd)
                        .submitLabel(.done)
                        .onSubmit { finishEditing() }

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
                } else {
                    Text(task.task)
                        .font(DesignSystem.Typography.bodyMd)
                        .strikethrough(task.isCompleted, color: DesignSystem.Colors.onSurfaceVariant)
                        .foregroundColor(
                            task.isCompleted
                                ? DesignSystem.Colors.onSurfaceVariant.opacity(0.4)
                                : DesignSystem.Colors.onSurfaceVariant
                        )

                    if let time = task.time, !time.isEmpty {
                        Text(time)
                            .font(DesignSystem.Typography.labelSm)
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.4))
                    }
                }
            }

            Spacer()

            // 우측 액션 버튼
            HStack(spacing: 16) {
                Button(action: {
                    // 향후 음성 수정 기능 (P3)
                }) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 18))
                }
                .disabled(isEditing)

                Button(action: {
                    withAnimation {
                        if isEditing { finishEditing() } else { startEditing() }
                    }
                }) {
                    Image(systemName: isEditing ? "checkmark" : "pencil")
                        .font(.system(size: 18))
                }
            }
            .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.2))
        }
        .padding(.horizontal, 32)
        .opacity(isDimmed ? 0.3 : 1.0)
        .onAppear {
            localTaskName = task.task
            localTime     = task.time ?? ""
        }
        .onChange(of: editingTaskId) { newValue in
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
        // 변경 내용 AppTask에 반영 후 저장
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

// MARK: - Preview
struct RoutineView_Previews: PreviewProvider {
    static var previews: some View {
        RoutineView()
            .environmentObject(TaskManager())
    }
}

// MARK: - Time Picker Modal
struct TimePickerModal: View {
    @Binding var timeString: String
    @Binding var isPresented: Bool
    @State private var selectedDate: Date

    init(timeString: Binding<String>, isPresented: Binding<Bool>) {
        self._timeString   = timeString
        self._isPresented  = isPresented

        let formatter = DateFormatter()
        formatter.locale     = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "hh:mm a"
        if let date = formatter.date(from: timeString.wrappedValue) {
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
                let formatter = DateFormatter()
                formatter.locale     = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "hh:mm a"
                timeString  = formatter.string(from: selectedDate)
                isPresented = false
            }
            .font(.system(size: 16, weight: .semibold))
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
