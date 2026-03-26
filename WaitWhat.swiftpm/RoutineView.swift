import SwiftUI

struct RoutineView: View {
    @EnvironmentObject var taskManager: TaskManager
    @State private var editingTaskId: UUID?

    var body: some View {
        ZStack(alignment: .bottom) {
            // 1. Off-white background
            DesignSystem.Colors.background
                .ignoresSafeArea()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 48) { // 부드럽고 시원한 여백 유지
                    
                    // 영역: My Routines Title
                    Text("My Routines")
                        .font(DesignSystem.Typography.displayLg)
                        .foregroundColor(DesignSystem.Colors.primary) // 시각적 위계 높은 제목
                        .tracking(-0.5)
                        .padding(.top, 16) // 위쪽 여백 축소 (시각적 밸런스 조정)
                        .padding(.horizontal, 32)
                    
                    // 영역: Daily Routines
                    VStack(alignment: .leading, spacing: 32) {
                        Text("Daily Routines")
                            .font(DesignSystem.Typography.titleSm)
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                            .padding(.horizontal, 32)
                        
                        LazyVStack(spacing: 32) { // 항목 간 여백 넓게
                            ForEach($taskManager.routines) { $routine in
                                if !routine.isCompleted {
                                    TaskRow(routine: $routine, editingTaskId: $editingTaskId)
                                }
                            }
                            ForEach($taskManager.routines) { $routine in
                                if routine.isCompleted {
                                    TaskRow(routine: $routine, editingTaskId: $editingTaskId)
                                }
                            }
                        }
                    }
                    
                    // 영역: Today's Tasks
                    VStack(alignment: .leading, spacing: 32) {
                        Text("Today's Tasks")
                            .font(DesignSystem.Typography.titleSm)
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                            .padding(.horizontal, 32)
                        
                        LazyVStack(spacing: 32) {
                            ForEach($taskManager.appointments) { $appointment in
                                if !appointment.isCompleted {
                                    TaskRow(routine: $appointment, editingTaskId: $editingTaskId)
                                }
                            }
                            ForEach($taskManager.appointments) { $appointment in
                                if appointment.isCompleted {
                                    TaskRow(routine: $appointment, editingTaskId: $editingTaskId)
                                }
                            }
                        }
                    }
                    
                    // 바텀 플로팅 바가 텍스트를 가리지 않도록 공간 확보
                    Spacer(minLength: 140)
                }
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }
}

// MARK: - Task Row Component (할 일 항복 컴포넌트)
struct TaskRow: View {
    @Binding var routine: ParsedTask
    @Binding var editingTaskId: UUID?
    @FocusState private var isTitleFocused: Bool
    @State private var showingTimePicker = false
    
    var isEditing: Bool {
        editingTaskId == routine.id
    }
    
    var isDimmed: Bool {
        editingTaskId != nil && editingTaskId != routine.id
    }
    
    var body: some View {
        HStack(spacing: 20) {
            // 1. 좌측: 크고 명확한 원형 체크박스
            Button(action: {
                // 부드러운 상태 전환 곡선 적용 (DESIGN.md 규칙: soft transitions)
                withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.3)) {
                    routine.isCompleted.toggle()
                }
            }) {
                ZStack {
                    Circle()
                        .stroke(DesignSystem.Colors.onSurfaceVariant.opacity(0.3), lineWidth: 1.5)
                        .frame(width: 32, height: 32)
                    
                    if routine.isCompleted {
                        Circle()
                            // 체크 시엔 성공 피드백, Tertiary 컬러 사용
                            .fill(DesignSystem.Colors.tertiary)
                            .frame(width: 32, height: 32)
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
            }
            .disabled(isEditing)
            
            // 2. 중앙: 할 일 제목과 흐릿한(Muted) 시간 텍스트
            VStack(alignment: .leading, spacing: 6) {
                if isEditing {
                    TextField("Task", text: $routine.task)
                        .focused($isTitleFocused)
                        .font(DesignSystem.Typography.bodyMd)
                        .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                        .submitLabel(.done)
                        .onSubmit { finishEditing() }
                    
                    Text(routine.time?.isEmpty == false ? routine.time! : "Set Time")
                        .font(DesignSystem.Typography.labelSm)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(DesignSystem.Colors.onSurfaceVariant.opacity(0.1))
                        .cornerRadius(6)
                        .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                        .onTapGesture {
                            showingTimePicker = true
                        }
                        .sheet(isPresented: $showingTimePicker) {
                            TimePickerModal(timeString: $routine.time, isPresented: $showingTimePicker)
                        }
                } else {
                    Text(routine.task)
                        .font(DesignSystem.Typography.bodyMd)
                        .strikethrough(routine.isCompleted, color: DesignSystem.Colors.onSurfaceVariant)
                        // 완료되면 본문 색상도 대비를 낮춰서 뒤로 물리게 함
                        .foregroundColor(routine.isCompleted ? DesignSystem.Colors.onSurfaceVariant.opacity(0.4) : DesignSystem.Colors.onSurfaceVariant)
                    
                    if let time = routine.time, !time.isEmpty {
                        Text(time)
                            .font(DesignSystem.Typography.labelSm)
                            // 시각적 노이즈를 줄이기 위한 매우 연한 톤 (Muted gray)
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.4))
                    }
                }
            }
            
            Spacer()
            
            // 3. 우측: 극단적으로 대비를 낮춘 수정 및 음성(마이크) 툴 아이콘
            HStack(spacing: 16) {
                Button(action: { 
                    // TODO: 나중에 마이크 음성 수정 기능 구현 (Routine P3)
                }) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 18))
                }
                .disabled(isEditing)
                
                Button(action: { 
                    withAnimation {
                        if isEditing {
                            finishEditing()
                        } else {
                            startEditing()
                        }
                    }
                }) {
                    Image(systemName: isEditing ? "checkmark" : "pencil")
                        .font(.system(size: 18))
                }
            }
            // 낮춤 대비(Low-contrast)로 주의력 뺏지 않음
            .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.2))
        }
        .padding(.horizontal, 32)
        .opacity(isDimmed ? 0.3 : 1.0)
        .onChange(of: editingTaskId) { newValue in
            if newValue == routine.id {
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
                        withAnimation {
                            finishEditing()
                        }
                    }
                }
            }
        }
    }
    
    private func finishEditing() {
        if editingTaskId == routine.id {
            editingTaskId = nil
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
    
    private func startEditing() {
        editingTaskId = routine.id
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

// MARK: - Time Picker Modal Component
struct TimePickerModal: View {
    @Binding var timeString: String?
    @Binding var isPresented: Bool
    @State private var selectedDate: Date
    
    init(timeString: Binding<String?>, isPresented: Binding<Bool>) {
        self._timeString = timeString
        self._isPresented = isPresented
        
        let formatter = DateFormatter()
        formatter.dateFormat = "hh:mm a"
        if let ts = timeString.wrappedValue, let date = formatter.date(from: ts) {
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
                formatter.dateFormat = "hh:mm a"
                timeString = formatter.string(from: selectedDate)
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
