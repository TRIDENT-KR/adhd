import SwiftUI

// MARK: - Home Voice Interface View
struct HomeVoiceInterfaceView: View {
    @EnvironmentObject var cloudLLM: CloudLLMManager
    @EnvironmentObject var taskManager: TaskManager
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var networkMonitor: NetworkMonitor
    
    @ObservedObject var langManager = LocalizationManager.shared
    @StateObject private var voiceManager = VoiceInputManager()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBreathing = false
    @State private var showSuccessCheck = false
    @State private var showSettings = false

    @State private var showVoiceGuide = false
    @State private var shakeOffset: CGFloat = 0
    @State private var showErrorToast = false
    @State private var errorToastMessage = ""
    @AppStorage("hasSeenVoiceOnboarding") private var hasSeenVoiceOnboarding = false
    @AppStorage("confirmBeforeSave") private var confirmBeforeSave = true

    // Confirmation card state
    @State private var pendingTasks: [PendingLLMCall] = []
    @State private var showConfirmation = false
    @State private var editingTask: PendingLLMCall? = nil
    
    // Binding to pass modal state up to parent (MainTabView)
    @Binding var isModalVisible: Bool

    // Text input state
    @State private var showTextInput = false
    @State private var textInputValue = ""
    @FocusState private var isTextInputFocused: Bool

    var body: some View {
        ZStack {
            DesignSystem.Colors.background
                .ignoresSafeArea()

            VStack {
                // Top Bar
                HStack {
                    // 텍스트 입력 토글
                    Button(action: {
                        let anim: Animation? = reduceMotion ? .none : .spring(response: 0.3, dampingFraction: 0.8)
                        withAnimation(anim) {
                            showTextInput.toggle()
                            if showTextInput {
                                isTextInputFocused = true
                            }
                        }
                    }) {
                        Image(systemName: showTextInput ? "mic.fill" : "keyboard")
                            .font(.title3.weight(.medium))
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(showTextInput ? "Switch to voice input" : "Switch to text input")

                    Spacer()

                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape")
                            .font(.title3.weight(.medium))
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(L.settings.title)
                    .accessibilityHint("Double tap to open settings")
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)

                if showTextInput {
                    // ── 텍스트 입력 모드 ──
                    Spacer()

                    VStack(spacing: 20) {
                        Image(systemName: "keyboard")
                            .font(.system(size: 40))
                            .foregroundColor(DesignSystem.Colors.primary.opacity(0.4))
                            .accessibilityHidden(true)

                        HStack(spacing: 12) {
                            TextField(L.voice.textInputPlaceholder, text: $textInputValue)
                                .font(.body.weight(.medium))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 14)
                                        .fill(DesignSystem.Colors.surfaceContainerLow)
                                )
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                                .focused($isTextInputFocused)
                                .submitLabel(.send)
                                .onSubmit { sendTextInput() }

                            Button(action: { sendTextInput() }) {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.title.weight(.medium))
                                    .foregroundColor(textInputValue.trimmingCharacters(in: .whitespaces).isEmpty
                                        ? DesignSystem.Colors.onSurfaceVariant.opacity(0.4)
                                        : DesignSystem.Colors.primary)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .disabled(textInputValue.trimmingCharacters(in: .whitespaces).isEmpty || cloudLLM.isProcessing)
                            .accessibilityLabel("Send text input")
                            .accessibilityHint("Double tap to analyze the entered text")
                        }
                        .padding(.horizontal, 24)

                        if cloudLLM.isProcessing {
                            Text(L.voiceAnalyzing)
                                .font(DesignSystem.Typography.bodyMd)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.6))
                        }
                    }

                    Spacer()
                    Spacer(minLength: 120)
                } else {
                // ── 음성 입력 모드 (기존) ──
                Spacer()

                VStack(spacing: 32) {

                    // ── Voice Pulse + Mic Button + Timer ──
                    ZStack {
                        let pulseScale = voiceManager.isListening
                            ? 1.0 + (voiceManager.audioPower * 0.5)
                            : (isBreathing ? 1.08 : 0.92)

                        let pulseOpacity = voiceManager.isListening
                            ? 0.6
                            : (isBreathing ? 0.4 : 0.15)

                        Circle()
                            .fill(DesignSystem.Colors.primaryFixedDim.opacity(reduceMotion ? 0.3 : pulseOpacity))
                            .frame(width: 180, height: 180)
                            .scaleEffect(reduceMotion ? 1.0 : pulseScale)
                            .animation(
                                reduceMotion ? .none : (voiceManager.isListening
                                    ? .easeOut(duration: 0.1)
                                    : .easeInOut(duration: 2.0).repeatForever(autoreverses: true)),
                                value: pulseScale
                            )
                            .accessibilityHidden(true)

                        // ── 녹음 진행률 원형 프로그레스 ──
                        if voiceManager.isListening {
                            Circle()
                                .trim(from: 0, to: min(voiceManager.recordingDuration / VoiceInputManager.maxRecordingDuration, 1.0))
                                .stroke(
                                    DesignSystem.Colors.primary.opacity(0.6),
                                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                                )
                                .frame(width: 140, height: 140)
                                .rotationEffect(.degrees(-90))
                                .animation(reduceMotion ? .none : .linear(duration: 0.5), value: voiceManager.recordingDuration)
                                .accessibilityHidden(true)
                        }

                        // Mic button with Hold-to-Talk or Tap gesture
                        micButton
                            .offset(x: shakeOffset)
                            .accessibilityLabel(voiceManager.isListening ? L.voice.a11yStopRecording : L.voice.a11yStartRecording)
                            .accessibilityHint(voiceManager.micMode == .holdToTalk ? L.voice.a11yHoldHint : L.voice.a11yTapHint)
                    }
                    .onAppear {
                        isBreathing = true
                        setupSpeechCallback()
                    }


                    // ── 녹음 타이머 + 침묵 카운트다운 ──
                    if voiceManager.isListening {
                        VStack(spacing: 6) {
                            Text(formatDuration(voiceManager.recordingDuration))
                                .font(.callout.weight(.medium).monospaced())
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.7))

                            // 침묵 카운트다운 표시
                            if voiceManager.silenceCountdown > 0 {
                                Text("\(L.voice.silenceCountdown) \(voiceManager.silenceCountdown)...")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(DesignSystem.Colors.primary)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }

                    // ── 상태 텍스트 / 성공 체크 ──
                    Group {
                        if showConfirmation {
                            // 확인 카드가 표시될 때는 비움
                            EmptyView()
                        } else if showSuccessCheck {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 48))
                                .foregroundColor(DesignSystem.Colors.tertiary)
                                .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                                .accessibilityLabel("Task saved successfully")
                        } else if cloudLLM.isProcessing || voiceManager.isProcessing {
                            Text(L.voiceAnalyzing)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                        } else if voiceManager.isListening && !voiceManager.recognizedText.isEmpty {
                            // 실시간 텍스트 + 블링킹 커서
                            HStack(spacing: 0) {
                                Text(voiceManager.recognizedText)
                                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                                BlinkingCursor()
                            }
                        } else if !voiceManager.recognizedText.isEmpty {
                            Text(voiceManager.recognizedText)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                        } else if voiceManager.isListening {
                            Text(L.voiceListening)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                        } else {
                            VStack(spacing: 8) {
                                Text(L.voicePlaceholder)
                                    .foregroundColor(DesignSystem.Colors.primary)

                                if !hasSeenVoiceOnboarding {
                                    Text(L.voice.guideHint)
                                        .font(DesignSystem.Typography.labelSm)
                                        .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.4))
                                }
                            }
                        }
                    }
                    .font(DesignSystem.Typography.titleSm)
                    .tracking(-0.5)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .animation(.easeInOut, value: voiceManager.isListening)
                    .animation(.easeInOut, value: showSuccessCheck)
                }

                Spacer()
                Spacer(minLength: 120)
                } // end if-else showTextInput
            }

            if showConfirmation {
                ZStack {
                    // Background Dim (Blurry Material)
                    Rectangle()
                        .fill(.ultraThinMaterial.opacity(0.8))
                        .ignoresSafeArea()
                        .onTapGesture { cancelPendingTasks() }
                        .transition(.opacity)

                    VoiceConfirmationSheet(
                        tasks: $pendingTasks,
                        editingTask: $editingTask,
                        onConfirm: { confirmPendingTasks() },
                        onCancel: { cancelPendingTasks() }
                    )
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.95)),
                        removal: .opacity.combined(with: .scale(scale: 0.95))
                    ))
                }
                .ignoresSafeArea()
                .zIndex(20)
            }

            // ── 에러 토스트 ──
            if showErrorToast {
                VStack {
                    Spacer()

                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.body)
                            .foregroundColor(.white.opacity(0.9))

                        Text(errorToastMessage)
                            .font(.footnote.weight(.medium))
                            .foregroundColor(.white)

                        Spacer()

                        Button(action: {
                            withAnimation(reduceMotion ? .none : .easeOut(duration: 0.2)) {
                                showErrorToast = false
                            }
                            handleMicTap()
                        }) {
                            Text(L.voice.tryAgain)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(DesignSystem.Colors.primaryFixedDim)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Try again")
                        .accessibilityHint("Double tap to retry voice input")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color(UIColor { traits in
                                traits.userInterfaceStyle == .dark
                                    ? UIColor(r: 0x3A, g: 0x2A, b: 0x22)
                                    : UIColor(r: 0x4A, g: 0x30, b: 0x25)
                            }))
                    )
                    .padding(.horizontal, 24)
                    .padding(.bottom, 140)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        } // End main ZStack
        .edgesIgnoringSafeArea(.bottom)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(authManager)
                .environmentObject(taskManager)
        }
        .sheet(isPresented: $showVoiceGuide, onDismiss: {
            if !hasSeenVoiceOnboarding { hasSeenVoiceOnboarding = true }
        }) {
            VoiceGuideSheet()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: voiceManager.lastError) { _, newError in
            if let error = newError {
                triggerErrorFeedback(message: error.message)
                voiceManager.lastError = nil
            }
        }
        .onChange(of: showConfirmation) { _, isVisible in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                isModalVisible = isVisible
            }
        }
        .onAppear {
            isModalVisible = showConfirmation
        }
        .onReceive(NotificationCenter.default.publisher(for: .didReceiveOffTopicChat)) { notification in
            if let message = notification.userInfo?["message"] as? String {
                let call = LLMFunctionCall.handleOffTopicChat(OffTopicChatParams(message: message))
                pendingTasks = [PendingLLMCall(call: call)]
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    showConfirmation = true
                }
            }
        }
    }

    // MARK: - Mic Button (Tap vs Hold mode)
    @ViewBuilder
    private var micButton: some View {
        let buttonContent = ZStack {
            Circle()
                .fill(DesignSystem.Gradients.primaryCTA)
                .frame(width: 120, height: 120)

            Image(systemName: voiceManager.isListening ? "stop.fill" : "mic.fill")
                .font(.system(size: 40, weight: .medium))
                .foregroundColor(.white)
                .contentTransition(.symbolEffect(.replace))
        }

        if voiceManager.micMode == .holdToTalk {
            // Hold-to-Talk: 누르면 시작, 떼면 종료
            buttonContent
                .scaleEffect(voiceManager.isListening ? 0.93 : 1.0)
                .animation(.easeOut(duration: 0.2), value: voiceManager.isListening)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !voiceManager.isListening && !cloudLLM.isProcessing && !voiceManager.isProcessing {
                                handleMicTap()
                            }
                        }
                        .onEnded { _ in
                            if voiceManager.isListening {
                                voiceManager.stopListening()
                            }
                        }
                )
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 1.5)
                        .onEnded { _ in
                            Haptic.impact(.light)
                            showVoiceGuide = true
                        }
                )
        } else {
            // Tap-to-Toggle (기본)
            Button(action: { handleMicTap() }) {
                buttonContent
            }
            .buttonStyle(SquishyButtonStyle())
            .disabled(cloudLLM.isProcessing || voiceManager.isProcessing)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5)
                    .onEnded { _ in
                        Haptic.impact(.light)
                        showVoiceGuide = true
                    }
            )
        }
    }

    // MARK: - Text Input Handler
    private func sendTextInput() {
        let text = textInputValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }

        Haptic.impact(.medium)
        textInputValue = ""
        isTextInputFocused = false

        Task {
            do {
                let parsedTasks = try await cloudLLM.analyzeText(text: text)
                print("⌨️ 텍스트 입력 파싱 결과: \(parsedTasks)")

                await MainActor.run {
                        if confirmBeforeSave {
                            pendingTasks = parsedTasks.map { PendingLLMCall(call: $0) }
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                showConfirmation = true
                            }
                        } else {
                            taskManager.execute(llmCalls: parsedTasks)
                            if !parsedTasks.contains(where: { $0.isOffTopic }) {
                                showSuccessCheck = true
                                Haptic.notification(.success)
                            }
                        }
                    }

                    if !confirmBeforeSave && !parsedTasks.contains(where: { $0.isOffTopic }) {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        await MainActor.run { showSuccessCheck = false }
                    }
            } catch {
                print("❌ Text input API error: \(error.localizedDescription)")
                await MainActor.run {
                    triggerErrorFeedback(message: L.voice.errorApi)
                }
            }
        }
    }

    // MARK: - Mic Button Handler
    private func handleMicTap() {
        if !networkMonitor.isConnected && !voiceManager.isListening {
            networkMonitor.showOfflineBannerTemporarily()
            return
        }
        Haptic.impact(.medium)
        voiceManager.toggleListening()
    }

    // MARK: - Confirmation Actions
    private func confirmPendingTasks() {
        if let invalidTask = pendingTasks.first(where: { task in
            guard task.uiAction == "add" else { return false }
            let isMissingTime = task.uiTime == nil || task.uiTime!.isEmpty
            let isMissingDate = task.uiDate == nil || task.uiDate!.isEmpty
            
            if task.uiCategory == "Routine" && isMissingTime {
                return true
            } else if task.uiCategory == "Appointment" && (isMissingDate || isMissingTime) {
                return true
            }
            return false
        }) {
            withAnimation(.spring()) {
                self.editingTask = invalidTask
            }
            let errorMessage: String
            if invalidTask.uiCategory == "Routine" {
                errorMessage = L.voice.errorMissingTime
            } else {
                let isMissingDate = invalidTask.uiDate == nil || invalidTask.uiDate!.isEmpty
                errorMessage = isMissingDate ? L.voice.errorMissingDate : L.voice.errorMissingAppointmentTime
            }
            
            triggerErrorFeedback(message: errorMessage)
            return
        }
        
        // 알림 강도(Urgency) 정보를 포함하여 실행
        taskManager.execute(pendingCalls: pendingTasks)
        
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            showConfirmation = false
            pendingTasks = []
            showSuccessCheck = true
        }
        Haptic.notification(.success)

        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run {
                showSuccessCheck = false
            }
        }
    }

    private func cancelPendingTasks() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            showConfirmation = false
            pendingTasks = []
        }
    }

    // MARK: - Error Feedback
    private func triggerErrorFeedback(message: String) {
        withAnimation(.spring(response: 0.1, dampingFraction: 0.2)) {
            shakeOffset = 12
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.spring(response: 0.1, dampingFraction: 0.2)) {
                shakeOffset = -10
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.spring(response: 0.1, dampingFraction: 0.2)) {
                shakeOffset = 6
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.spring(response: 0.15, dampingFraction: 0.5)) {
                shakeOffset = 0
            }
        }

        Haptic.notification(.error)

        errorToastMessage = message
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            showErrorToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            withAnimation(.easeOut(duration: 0.3)) {
                showErrorToast = false
            }
        }
    }

    // MARK: - Duration Formatter
    private func formatDuration(_ duration: TimeInterval) -> String {
        let seconds = Int(duration)
        let remaining = Int(VoiceInputManager.maxRecordingDuration) - seconds
        return "0:\(String(format: "%02d", seconds)) / 0:\(String(format: "%02d", remaining > 0 ? remaining : 0))"
    }

    // MARK: - Speech Finalization Callback
    private func setupSpeechCallback() {
        guard voiceManager.onSpeechFinalized == nil else { return }
        voiceManager.onSpeechFinalized = { [weak voiceManager] text in
            guard let voiceManager else { return }

            Task {
                do {
                    let parsedTasks = try await cloudLLM.analyzeText(text: text)
                    print("🤖 Gemini 파싱 결과: \(parsedTasks)")

                    await MainActor.run {
                        voiceManager.recognizedText = ""
                        voiceManager.isProcessing   = false

                        if confirmBeforeSave {
                            // 확인 카드 표시
                            pendingTasks = parsedTasks.map { PendingLLMCall(call: $0) }
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                showConfirmation = true
                            }
                        } else {
                            // 바로 저장 (기존 동작)
                            taskManager.execute(llmCalls: parsedTasks)
                            if !parsedTasks.contains(where: { $0.isOffTopic }) {
                                showSuccessCheck = true
                                Haptic.notification(.success)
                            }
                        }
                    }

                    if !confirmBeforeSave && !parsedTasks.contains(where: { $0.isOffTopic }) {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        await MainActor.run {
                            showSuccessCheck = false
                        }
                    }
                } catch {
                    print("❌ Cloud API Error: \(error.localizedDescription)")
                    await MainActor.run {
                        voiceManager.recognizedText = ""
                        voiceManager.isProcessing   = false
                        voiceManager.lastError = .apiError(error.localizedDescription)
                    }
                }
            }
        }
    }
}

// MARK: - Blinking Cursor (isolated to avoid parent re-renders)
private struct BlinkingCursor: View {
    @State private var visible = true
    var body: some View {
        Text("|")
            .foregroundColor(DesignSystem.Colors.primary)
            .opacity(visible ? 1.0 : 0.0)
            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: visible)
            .onAppear { visible = false }
    }
}

// MARK: - Voice Confirmation Sheet (Floating Glass Card)
struct VoiceConfirmationSheet: View {
    @Binding var tasks: [PendingLLMCall]
    @Binding var editingTask: PendingLLMCall?
    
    // Edit fields
    @State private var editName: String = ""
    @State private var editCategory: String = "Routine"
    @State private var editDateTime: Date = Date()
    
    var onConfirm: () -> Void
    var onCancel: () -> Void
    
    // OOV(재치 있는 메시지) 상태 확인
    private var isOffTopic: Bool {
        tasks.contains { $0.call.isOffTopic }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                let titleText = editingTask == nil ? (isOffTopic ? "알림" : L.voice.confirmTitle) : L.voice.editTaskTitle
                Text(titleText)
                    .font(.title3.weight(.bold))
                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                
                Spacer()
                
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("Close")
                .accessibilityHint("Double tap to cancel")
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                if let currentEdit = editingTask, let index = tasks.firstIndex(where: { $0.id == currentEdit.id }) {
                    // --- Inline Edit Mode (Bubbles Style) ---
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 16) {
                            // Category Selection (Segmented)
                            Picker(L.voice.fieldCategory, selection: $editCategory) {
                                Text(L.voice.confirmAppointment).tag("Appointment")
                                Text(L.voice.confirmRoutine).tag("Routine")
                            }
                            .pickerStyle(.segmented)
                            
                            // Task Name Bubble
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L.voice.fieldName)
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.7))
                                
                                TextField(L.voice.fieldName, text: $editName)
                                    .padding(14)
                                    .background(Color(UIColor.systemBackground).opacity(0.6))
                                    .cornerRadius(12)
                            }
                            
                            // Time Bubble (Minimalist Picker)
                            HStack {
                                Text(L.voice.fieldTime)
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.7))
                                Spacer()
                                DatePicker("", selection: $editDateTime, displayedComponents: editCategory == "Appointment" ? [.date, .hourAndMinute] : [.hourAndMinute])
                                    .labelsHidden()
                                    .datePickerStyle(.compact)
                                    .environment(\.locale, Locale.current)
                            }
                            .padding(14)
                            .background(Color(UIColor.systemBackground).opacity(0.6))
                            .cornerRadius(12)
                        }
                        .padding(4)

                        // Internal Save/Cancel
                        HStack(spacing: 12) {
                            Button(L.voice.cancel) {
                                withAnimation(.spring()) { editingTask = nil }
                            }
                            .font(.subheadline.weight(.bold))
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.6))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)

                            Button(L.voice.save) {
                                let tf = DateFormatter()
                                tf.timeStyle = .short
                                tf.dateStyle = .none
                                let numStr = tf.string(from: editDateTime)
                                
                                let df = DateFormatter()
                                df.dateFormat = "yyyy-MM-dd"
                                let newDateStr = df.string(from: editDateTime)
                                
                                var updatedCall = tasks[index].call
                                updatedCall.updateFields(
                                    taskName: editName,
                                    time: numStr,
                                    date: newDateStr,
                                    category: editCategory
                                )
                                tasks[index].call = updatedCall
                                Haptic.impact(.light)
                                withAnimation(.spring()) { editingTask = nil }
                            }
                            .buttonStyle(SatisfyingButtonStyle(color: DesignSystem.Colors.primary))
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                    .onAppear {
                        editName = currentEdit.call.uiTaskName
                        editCategory = currentEdit.call.uiCategory
                        
                        let dateRaw = currentEdit.call.uiSmartDateRaw
                        let timeRaw = currentEdit.call.uiTime ?? ""
                        
                        let df = DateFormatter()
                        df.dateFormat = "yyyy-MM-dd"
                        var finalDate = df.date(from: dateRaw) ?? Date()
                        
                        if !timeRaw.isEmpty {
                            let tf = DateFormatter()
                            tf.timeStyle = .short
                            if let parsedTime = tf.date(from: timeRaw) {
                                let timeComponents = Calendar.current.dateComponents([.hour, .minute], from: parsedTime)
                                finalDate = Calendar.current.date(bySettingHour: timeComponents.hour ?? 0, minute: timeComponents.minute ?? 0, second: 0, of: finalDate) ?? finalDate
                            }
                        }
                        
                        editDateTime = finalDate
                    }
                } else {
                    // --- List Mode ---
                    VStack(spacing: 14) {
                        ForEach(tasks) { task in
                            VStack(alignment: .leading, spacing: 10) {
                                if !task.call.isOffTopic {
                                    HStack {
                                        let isPlanner = task.uiCategory == "Appointment"
                                        
                                        // High Contrast Badge
                                        let useCalendar = isPlanner && task.urgency == .strong
                                        Label(isPlanner ? L.voice.confirmAppointment : L.voice.confirmRoutine,
                                              systemImage: useCalendar ? "calendar" : (isPlanner ? "clock" : "repeat"))
                                            .font(.caption.weight(.bold))
                                            .foregroundColor(isPlanner ? DesignSystem.Colors.tertiary : DesignSystem.Colors.primary)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(isPlanner ? DesignSystem.Colors.tertiary.opacity(0.15) : DesignSystem.Colors.primary.opacity(0.15))
                                            .cornerRadius(8)

                                        Spacer()
                                        
                                        if task.uiAction != "add" {
                                            Text(task.uiActionLabel)
                                                .font(.caption2.weight(.black))
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(task.uiAction == "delete" ? Color.red.opacity(0.15) : Color.blue.opacity(0.15))
                                                .foregroundColor(task.uiAction == "delete" ? .red : .blue)
                                                .cornerRadius(6)
                                        }
                                    }
                                }

                                // Large Task Title
                                Text(task.uiTaskName)
                                    .font(.body.weight(.bold))
                                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                                
                                let smartDateTimeStr = task.uiSmartDateTime
                                if !smartDateTimeStr.isEmpty {
                                    HStack(spacing: 6) {
                                        Image(systemName: "clock.fill")
                                            .font(.caption)
                                            .accessibilityHidden(true)
                                        Text(smartDateTimeStr)
                                            .font(.footnote.weight(.semibold))
                                        
                                        Spacer()
                                        
                                        // Urgency Toggle (Strong/Weak)
                                        HStack(spacing: 4) {
                                            let isStrong = task.urgency == .strong
                                            Button {
                                                if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
                                                    tasks[idx].urgency = isStrong ? .weak : .strong
                                                }
                                            } label: {
                                                HStack(spacing: 4) {
                                                    Image(systemName: isStrong ? "bolt.fill" : "bolt")
                                                        .font(.caption2.weight(.bold))
                                                    Text(isStrong ? L.voice.urgencyStrong : L.voice.urgencyWeak)
                                                        .font(.caption2.weight(.bold))
                                                }
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .background(isStrong ? Color.orange.opacity(0.2) : Color.gray.opacity(0.1))
                                                .foregroundColor(isStrong ? .orange : Color.gray)
                                                .cornerRadius(20)
                                            }
                                        }
                                    }
                                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.6))
                                }
                            }
                            .padding(.vertical, 16)
                            .padding(.horizontal, 20)
                            // Clean white/dark surface background
                            .background(Color(UIColor.systemBackground).opacity(0.7))
                            .cornerRadius(24)
                            .overlay(
                                RoundedRectangle(cornerRadius: 24)
                                    .stroke(Color.white.opacity(0.5), lineWidth: 0.5)
                            )
                            .shadow(color: .black.opacity(0.03), radius: 8, x: 0, y: 4)
                            .onTapGesture {
                                withAnimation(.spring()) { editingTask = task }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                    
                    // The "Satisfying Hub" Confirm Button
                    Button(action: isOffTopic ? onCancel : onConfirm) {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                            Text(isOffTopic ? "다시 질문하기" : L.voice.confirmButton)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SatisfyingButtonStyle(color: DesignSystem.Colors.primary))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 28)
                }
            }
            .fixedSize(horizontal: false, vertical: true) // shrink-wraps height for < 4 items
        }
        .frame(maxWidth: 340) // slightly narrower
        // The modal background & glow
        .glassStyle(cornerRadius: 32)
        // Replaced muddy black shadow with a soft themed glow
        .shadow(color: DesignSystem.Colors.primary.opacity(0.15), radius: 40, x: 0, y: 15)
        .shadow(color: DesignSystem.Colors.onSurfaceVariant.opacity(0.05), radius: 10, x: 0, y: 5)
        .padding(.horizontal, 24)
        .padding(.vertical, 40)
    }
}

// MARK: - Task Edit Sheet
struct TaskEditSheet: View {
    @Binding var pendingCall: PendingLLMCall
    @Environment(\.dismiss) var dismiss

    @State private var taskName: String = ""
    @State private var time: String = ""
    @State private var category: String = "Routine"
    @State private var date: String = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(L.voice.fieldName)) {
                    TextField(L.voice.fieldName, text: $taskName)
                }
                
                Section(header: Text(L.voice.fieldTime)) {
                    TextField(L.voice.fieldTime + " (e.g. 10:00 AM)", text: $time)
                }
                
                Section(header: Text(L.voice.fieldCategory)) {
                    Picker(L.voice.fieldCategory, selection: $category) {
                        Text(L.voice.confirmAppointment).tag("Appointment")
                        Text(L.voice.confirmRoutine).tag("Routine")
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle(L.voice.editTaskTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.voice.cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L.voice.save) {
                        pendingCall.call.updateFields(
                            taskName: taskName,
                            time: time.isEmpty ? nil : time,
                            date: date.isEmpty ? nil : date,
                            category: category
                        )
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
            .onAppear {
                taskName = pendingCall.call.uiTaskName
                time = pendingCall.call.uiTime ?? ""
                category = pendingCall.call.uiCategory
                
                // Get original date if possible (though date editing is limited in this simplified UI)
                if case .addSingleTask(let p) = pendingCall.call {
                    date = p.date ?? ""
                } else if case .updateTask(let p) = pendingCall.call {
                    date = p.new_date ?? ""
                }
            }
        }
    }
}

// MARK: - Voice Guide Sheet (온보딩 + 예시 명령어)
struct VoiceGuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let examples: [(icon: String, text: String, color: Color)] = [
        ("plus.circle.fill", L.voice.exampleAdd, DesignSystem.Colors.tertiary),
        ("calendar.circle.fill", L.voice.exampleAppointment, DesignSystem.Colors.primary),
        ("minus.circle.fill", L.voice.exampleDelete, Color.red.opacity(0.7)),
    ]

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(DesignSystem.Colors.primary)
                    .accessibilityHidden(true)

                Text(L.voice.guideTitle)
                    .font(.title2.weight(.semibold))
                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
            }
            .padding(.top, 24)

            VStack(spacing: 16) {
                ForEach(Array(examples.enumerated()), id: \.offset) { _, example in
                    HStack(spacing: 16) {
                        Image(systemName: example.icon)
                            .font(.title3)
                            .foregroundColor(example.color)
                            .frame(width: 36)

                        Text(example.text)
                            .font(.body.weight(.medium))
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant)

                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(DesignSystem.Colors.surfaceContainerLow)
                    )
                }
            }
            .padding(.horizontal, 24)

            Spacer()
        }
        .background(DesignSystem.Colors.background)
    }
}

// MARK: - Notifications
extension Notification.Name {
    static let didReceiveOffTopicChat = Notification.Name("didReceiveOffTopicChat")
}

// MARK: - Preview
struct HomeVoiceInterfaceView_Previews: PreviewProvider {
    static var previews: some View {
        HomeVoiceInterfaceView(isModalVisible: .constant(false))
            .environmentObject(CloudLLMManager())
            .environmentObject(TaskManager())
            .environmentObject(AuthManager())
            .environmentObject(NetworkMonitor.shared)
    }
}
