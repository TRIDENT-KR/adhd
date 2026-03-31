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


    @Binding var activeTab: TabSelection
    @State private var editingTaskId: UUID?
    @State private var selectedSection: RoutineSection = .routines
    @State private var showSearch = false
    @State private var isReordering = false
    @State private var draggingTask: AppTask?

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

                    // 제목 + 검색 버튼
                    HStack {
                        Text(verbatim: "Routine")
                            .onAppear { setupVoiceEditCallback() }
                            .font(DesignSystem.Typography.displayLg)
                            .foregroundColor(DesignSystem.Colors.primary)
                            .tracking(-0.5)
                        Spacer()
                        Button(action: { showSearch = true }) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 20, weight: .light))
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.4))
                                .padding(12)
                                .contentShape(Circle())
                        }
                        .buttonStyle(NoEffectButtonStyle())
                    }
                    .padding(.top, 16)
                    .padding(.leading, 32)
                    .padding(.trailing, 20)

                    // 섹션 토글 + 정렬 버튼
                    HStack(spacing: 12) {
                        ForEach(RoutineSection.allCases, id: \.self) { section in
                            let isSelected = selectedSection == section
                            Button(action: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
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
                        }
                        Spacer()

                        // 정렬 모드 토글
                        Button(action: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                isReordering.toggle()
                                if isReordering { editingTaskId = nil }
                            }
                        }) {
                            Image(systemName: isReordering ? "checkmark.circle.fill" : "arrow.up.arrow.down")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(isReordering ? DesignSystem.Colors.tertiary : DesignSystem.Colors.onSurfaceVariant.opacity(0.4))
                        }
                    }
                    .padding(.horizontal, 32)

                    // 선택된 섹션의 태스크 목록
                    let currentTasks = selectedSection == .routines ? todayRoutines : todayAppointments

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
                    } else if isReordering {
                        // 정렬 모드: 드래그 핸들 표시
                        LazyVStack(spacing: 16) {
                            ForEach(currentTasks) { task in
                                ReorderRow(task: task, allTasks: currentTasks, taskManager: taskManager)
                            }
                        }
                    } else {
                        let (incomplete, completed) = currentTasks.partitioned { !$0.isCompleted }
                        LazyVStack(spacing: 32) {
                            ForEach(incomplete) { task in
                                TaskRow(task: task, editingTaskId: $editingTaskId, voiceManager: voiceManager, voiceEditingTaskId: $voiceEditingTaskId)
                                    .swipeToDelete {
                                        withAnimation { taskManager.delete(task: task) }
                                        Haptic.impact(.medium)
                                    }
                            }
                            ForEach(completed) { task in
                                TaskRow(task: task, editingTaskId: $editingTaskId, voiceManager: voiceManager, voiceEditingTaskId: $voiceEditingTaskId)
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
            .ignoresSafeArea(edges: .bottom)
        }
        .sheet(isPresented: $showSearch) {
            SearchView()
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
                let allTasks = todayRoutines + todayAppointments
                guard let target = allTasks.first(where: { $0.id == targetId }) else { return }

                target.task = text
                taskManager.update(task: target)
                Haptic.impact(.medium)
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
    @State private var localUrgency: Urgency  = .weak
    @State private var cachedCategoryIcon: String = "circle.fill"

    var isEditing: Bool { editingTaskId == task.id }
    var isDimmed:  Bool { editingTaskId != nil && editingTaskId != task.id }
    var isVoiceEditing: Bool { voiceEditingTaskId == task.id && voiceManager.isListening }

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
                Haptic.impact(.medium)
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

                    // urgency 토글
                    Button(action: {
                        localUrgency = (localUrgency == .weak) ? .strong : .weak
                        Haptic.impact(.light)
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: localUrgency == .strong ? "bolt.fill" : "bolt")
                                .font(.system(size: 11, weight: .semibold))
                            Text(localUrgency == .strong ? "Strong" : "Weak")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(localUrgency == .strong ? .orange : DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background((localUrgency == .strong ? Color.orange : DesignSystem.Colors.onSurfaceVariant).opacity(0.12))
                        .cornerRadius(6)
                    }
                    .buttonStyle(NoEffectButtonStyle())
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
                        HStack(spacing: 4) {
                            Text(time)
                                .font(DesignSystem.Typography.labelSm)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.4))
                            if let label = task.recurrenceLabel {
                                Image(systemName: "repeat")
                                    .font(.system(size: 9))
                                Text(label)
                                    .font(.system(size: 11))
                            }
                            if task.urgency == .strong {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(.orange.opacity(0.7))
                            }
                        }
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
                        Haptic.impact(.medium)
                    }) {
                        Image(systemName: "trash")
                            .font(.system(size: 16))
                            .foregroundColor(.red.opacity(0.6))
                    }

                    Button(action: {
                        finishEditing()
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
            // 키보드 초기화 블로킹 방지: 충분한 지연 후 포커스
            try? await Task.sleep(nanoseconds: 500_000_000)
            isTitleFocused = true
        }
    }

    private func finishEditing() {
        guard editingTaskId == task.id else { return }
        // 변경 내용 AppTask에 반영 후 저장
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

    private func handleVoiceEdit() {
        if voiceManager.isListening && voiceEditingTaskId == task.id {
            // 녹음 중지 → onSpeechFinalized에서 태스크 업데이트
            voiceManager.stopListening()
        } else {
            // 녹음 시작
            voiceEditingTaskId = task.id
            voiceManager.startListening()
            Haptic.impact(.medium)
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
                            offset = -(UIApplication.shared.connectedScenes
                                .compactMap { $0 as? UIWindowScene }
                                .first?.screen.bounds.width ?? 400)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            onDelete()
                        }
                    }) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 18))
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

// MARK: - Reorder Row Component
struct ReorderRow: View {
    var task: AppTask
    let allTasks: [AppTask]
    let taskManager: TaskManager

    private var currentIndex: Int {
        allTasks.firstIndex(where: { $0.id == task.id }) ?? 0
    }
    private var isFirst: Bool { currentIndex == 0 }
    private var isLast: Bool { currentIndex == allTasks.count - 1 }

    var body: some View {
        HStack(spacing: 16) {
            // 드래그 핸들
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.3))

            // 완료 표시
            Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundColor(task.isCompleted ? DesignSystem.Colors.tertiary : DesignSystem.Colors.onSurfaceVariant.opacity(0.25))

            // 태스크 이름
            VStack(alignment: .leading, spacing: 2) {
                Text(task.task)
                    .font(DesignSystem.Typography.bodyMd)
                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                    .lineLimit(1)
                if let time = task.time, !time.isEmpty {
                    Text(time)
                        .font(DesignSystem.Typography.labelSm)
                        .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.4))
                }
            }

            Spacer()

            // 위/아래 이동 버튼
            HStack(spacing: 8) {
                Button(action: { moveUp() }) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(isFirst ? DesignSystem.Colors.onSurfaceVariant.opacity(0.1) : DesignSystem.Colors.primary)
                }
                .disabled(isFirst)

                Button(action: { moveDown() }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(isLast ? DesignSystem.Colors.onSurfaceVariant.opacity(0.1) : DesignSystem.Colors.primary)
                }
                .disabled(isLast)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 32)
        .background(DesignSystem.Colors.surfaceContainerLow.opacity(0.5))
        .cornerRadius(12)
        .padding(.horizontal, 24)
    }

    private func moveUp() {
        guard !isFirst else { return }
        let idx = currentIndex
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            swapOrder(allTasks[idx], allTasks[idx - 1])
        }
        Haptic.impact(.light)
    }

    private func moveDown() {
        guard !isLast else { return }
        let idx = currentIndex
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            swapOrder(allTasks[idx], allTasks[idx + 1])
        }
        Haptic.impact(.light)
    }

    private func swapOrder(_ a: AppTask, _ b: AppTask) {
        let tempOrder = a.sortOrder
        a.sortOrder = b.sortOrder
        b.sortOrder = tempOrder

        // 같은 값이었으면 강제로 분리
        if a.sortOrder == b.sortOrder {
            // 전체 목록에 순서를 재할당
            for (i, t) in allTasks.enumerated() {
                t.sortOrder = (i + 1) * 10
            }
        }
        taskManager.safeSave()
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
