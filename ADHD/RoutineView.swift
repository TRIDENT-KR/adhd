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

    @Binding var activeTab: TabSelection
    @State private var editingTaskId: UUID?
    @State private var selectedSection: RoutineSection = .routines

    enum RoutineSection: CaseIterable {
        case routines, tasks

        var label: String {
            switch self {
            case .routines: return L.routineDailySection
            case .tasks: return L.routineTodaySection
            }
        }
    }
    @StateObject private var voiceManager = VoiceInputManager()
    @State private var voiceEditingTaskId: UUID?

    var body: some View {
        ZStack(alignment: .bottom) {
            DesignSystem.Colors.background
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 48) {

                    // 제목
                    Text(L.routineTitle)
                        .onAppear { setupVoiceEditCallback() }
                        .font(DesignSystem.Typography.displayLg)
                        .foregroundColor(DesignSystem.Colors.primary)
                        .tracking(-0.5)
                        .padding(.top, 16)
                        .padding(.horizontal, 32)

                    // 섹션 토글 (Zero Clutter: 한 번에 하나의 섹션만 표시)
                    HStack(spacing: 12) {
                        ForEach(RoutineSection.allCases, id: \.self) { section in
                            let isSelected = selectedSection == section
                            Button(action: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    selectedSection = section
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
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 32)

                    // 선택된 섹션의 태스크 목록
                    let currentTasks = selectedSection == .routines ? routines : appointments

                    if currentTasks.isEmpty {
                        // Empty State: 화면 중앙 정렬
                        GeometryReader { geo in
                            VStack(spacing: 20) {
                                Image(systemName: "mic.fill")
                                    .font(.system(size: 48))
                                    .foregroundColor(DesignSystem.Colors.primary.opacity(0.3))

                                Text(selectedSection == .routines
                                     ? L.routineEmptyRoutine
                                     : L.routineEmptyTask)
                                    .font(DesignSystem.Typography.bodyMd)
                                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.6))
                            }
                            .frame(width: geo.size.width, height: geo.size.height)
                            .onTapGesture {
                                withAnimation(.spring()) { activeTab = .voice }
                            }
                        }
                        .frame(minHeight: ((UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.height ?? 800) * 0.45)
                    } else {
                        let (incomplete, completed) = currentTasks.partitioned { !$0.isCompleted }
                        LazyVStack(spacing: 32) {
                            ForEach(incomplete) { task in
                                TaskRow(task: task, editingTaskId: $editingTaskId, voiceManager: voiceManager, voiceEditingTaskId: $voiceEditingTaskId)
                            }
                            ForEach(completed) { task in
                                TaskRow(task: task, editingTaskId: $editingTaskId, voiceManager: voiceManager, voiceEditingTaskId: $voiceEditingTaskId)
                            }
                        }
                    }

                    Spacer(minLength: 140)
                }
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }

    // MARK: - Voice Edit Callback
    private func setupVoiceEditCallback() {
        voiceManager.onSpeechFinalized = { [weak voiceManager] text in
            Task { @MainActor in
                defer {
                    voiceEditingTaskId = nil
                    voiceManager?.isProcessing = false
                }

                guard !text.isEmpty, let targetId = voiceEditingTaskId else { return }

                // 모든 태스크에서 편집 대상 찾기
                let allTasks = routines + appointments
                guard let target = allTasks.first(where: { $0.id == targetId }) else { return }

                target.task = text
                taskManager.update(task: target)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
    }
}

// MARK: - Task Row Component
struct TaskRow: View {
    /// AppTask는 @Model 참조 타입이므로 직접 참조하여 수정합니다.
    var task: AppTask
    @Binding var editingTaskId: UUID?
    @ObservedObject var voiceManager: VoiceInputManager
    @Binding var voiceEditingTaskId: UUID?

    @EnvironmentObject private var taskManager: TaskManager
    @Environment(\.modelContext) private var modelContext

    @FocusState private var isTitleFocused: Bool
    @State private var showingTimePicker = false
    @State private var localTaskName: String = ""
    @State private var localTime: String     = ""
    @State private var cachedCategoryIcon: String = "circle.fill"

    var isEditing: Bool { editingTaskId == task.id }
    var isDimmed:  Bool { editingTaskId != nil && editingTaskId != task.id }
    var isVoiceEditing: Bool { voiceEditingTaskId == task.id && voiceManager.isListening }

    /// 태스크명에서 키워드 매칭으로 카테고리 아이콘 결정 (Visual Anchor)
    private static func resolveIcon(for taskName: String, category: String?) -> String {
        let name = taskName.lowercased()
        if name.contains("exercise") || name.contains("workout") || name.contains("run") || name.contains("gym") {
            return "figure.run"
        } else if name.contains("medicine") || name.contains("pill") || name.contains("drug") || name.contains("vitamin") {
            return "pill.fill"
        } else if name.contains("meal") || name.contains("eat") || name.contains("breakfast") || name.contains("lunch") || name.contains("dinner") || name.contains("cook") {
            return "fork.knife"
        } else if name.contains("sleep") || name.contains("bed") || name.contains("wake") || name.contains("alarm") {
            return "alarm.fill"
        } else if name.contains("study") || name.contains("read") || name.contains("book") || name.contains("learn") {
            return "book.fill"
        } else if name.contains("meeting") || name.contains("call") || name.contains("zoom") {
            return "phone.fill"
        } else if name.contains("clean") || name.contains("laundry") || name.contains("wash") {
            return "bubbles.and.sparkles.fill"
        } else if name.contains("walk") || name.contains("dog") || name.contains("pet") {
            return "pawprint.fill"
        } else if name.contains("water") || name.contains("drink") || name.contains("hydrat") {
            return "drop.fill"
        } else if category == "Appointment" {
            return "calendar"
        } else {
            return "circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 20) {
            // 카테고리 아이콘 앵커 (Visual Anchor)
            Image(systemName: cachedCategoryIcon)
                .font(.system(size: 14))
                .foregroundColor(DesignSystem.Colors.primary.opacity(task.isCompleted ? 0.2 : 0.5))
                .frame(width: 20)

            // 체크박스
            Button(action: {
                withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.3)) {
                    taskManager.toggleCompletion(of: task)
                }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }) {
                ZStack {
                    Circle()
                        .stroke(DesignSystem.Colors.onSurfaceVariant.opacity(0.3), lineWidth: 1.5)
                        .frame(width: 32, height: 32)

                    if task.isCompleted {
                        Circle()
                            .fill(DesignSystem.Colors.tertiary)
                            .frame(width: 32, height: 32)
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
            }
            .disabled(isEditing)
            .accessibilityLabel(task.isCompleted ? "\(task.task), completed" : "\(task.task), not completed")
            .accessibilityHint("Double tap to toggle completion")

            // 텍스트 / 편집 영역
            VStack(alignment: .leading, spacing: 6) {
                if isEditing {
                    TextField("Task", text: $localTaskName)
                        .focused($isTitleFocused)
                        .font(DesignSystem.Typography.bodyMd)
                        .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
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
                } else if isVoiceEditing {
                    // 음성 편집 중: 실시간 인식 텍스트 표시
                    Text(voiceManager.recognizedText.isEmpty ? "Listening..." : voiceManager.recognizedText)
                        .font(DesignSystem.Typography.bodyMd)
                        .foregroundColor(DesignSystem.Colors.primary)
                        .animation(.easeInOut, value: voiceManager.recognizedText)
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
                if isEditing {
                    // 편집 모드: 삭제 + 완료
                    Button(action: {
                        withAnimation {
                            taskManager.delete(task: task)
                            editingTaskId = nil
                        }
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }) {
                        Image(systemName: "trash")
                            .font(.system(size: 16))
                            .foregroundColor(.red.opacity(0.6))
                    }

                    Button(action: {
                        withAnimation { finishEditing() }
                    }) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 18))
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.2))
                    }
                } else {
                    // 기본 모드: 마이크 + 편집
                    Button(action: {
                        handleVoiceEdit()
                    }) {
                        Image(systemName: isVoiceEditing ? "stop.fill" : "mic.fill")
                            .font(.system(size: 18))
                            .foregroundColor(isVoiceEditing ? DesignSystem.Colors.primary : DesignSystem.Colors.onSurfaceVariant.opacity(0.2))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .disabled(voiceEditingTaskId != nil && voiceEditingTaskId != task.id)

                    Button(action: {
                        withAnimation { startEditing() }
                    }) {
                        Image(systemName: "pencil")
                            .font(.system(size: 18))
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.2))
                    }
                }
            }
        }
        .padding(.horizontal, 32)
        .opacity(isDimmed ? 0.3 : 1.0)
        .onAppear {
            localTaskName = task.task
            localTime     = task.time ?? ""
            cachedCategoryIcon = Self.resolveIcon(for: task.task, category: task.category)
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
        cachedCategoryIcon = Self.resolveIcon(for: localTaskName, category: task.category)
        editingTaskId = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func startEditing() {
        editingTaskId = task.id
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func handleVoiceEdit() {
        if voiceManager.isListening && voiceEditingTaskId == task.id {
            // 녹음 중지 → onSpeechFinalized에서 태스크 업데이트
            voiceManager.stopListening()
        } else {
            // 녹음 시작
            voiceEditingTaskId = task.id
            voiceManager.startListening()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
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

// MARK: - Array Partition Helper
private extension Array {
    /// Single-pass partition into (matching, non-matching) — avoids two separate .filter() calls.
    func partitioned(by predicate: (Element) -> Bool) -> ([Element], [Element]) {
        var matching: [Element] = []
        var rest: [Element] = []
        for element in self {
            if predicate(element) {
                matching.append(element)
            } else {
                rest.append(element)
            }
        }
        return (matching, rest)
    }
}
