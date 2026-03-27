import SwiftUI

// MARK: - Home Voice Interface View
struct HomeVoiceInterfaceView: View {
    @EnvironmentObject var cloudLLM: CloudLLMManager
    @EnvironmentObject var taskManager: TaskManager
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var networkMonitor: NetworkMonitor
    @StateObject private var voiceManager = VoiceInputManager()
    @State private var isBreathing = false
    @State private var showPlaceholder = true
    @State private var showSuccessCheck = false
    @State private var showSettings = false
    @State private var showVoiceGuide = false
    @State private var shakeOffset: CGFloat = 0
    @State private var showErrorToast = false
    @State private var errorToastMessage = ""
    @State private var cursorVisible = true
    @AppStorage("hasSeenVoiceOnboarding") private var hasSeenVoiceOnboarding = false
    @AppStorage("confirmBeforeSave") private var confirmBeforeSave = true

    // Confirmation card state
    @State private var pendingTasks: [ParsedTask] = []
    @State private var showConfirmation = false

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
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            showTextInput.toggle()
                            if showTextInput {
                                isTextInputFocused = true
                            }
                        }
                    }) {
                        Image(systemName: showTextInput ? "mic.fill" : "keyboard")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                    }

                    Spacer()

                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                    }
                    .accessibilityLabel(L.settings.title)
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

                        HStack(spacing: 12) {
                            TextField(L.voice.textInputPlaceholder, text: $textInputValue)
                                .font(.system(size: 16, weight: .medium))
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
                                    .font(.system(size: 36))
                                    .foregroundColor(textInputValue.trimmingCharacters(in: .whitespaces).isEmpty
                                        ? DesignSystem.Colors.onSurfaceVariant.opacity(0.2)
                                        : DesignSystem.Colors.primary)
                            }
                            .disabled(textInputValue.trimmingCharacters(in: .whitespaces).isEmpty || cloudLLM.isProcessing)
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
                            .fill(DesignSystem.Colors.primaryFixedDim.opacity(pulseOpacity))
                            .frame(width: 180, height: 180)
                            .scaleEffect(pulseScale)
                            .animation(
                                voiceManager.isListening
                                    ? .easeOut(duration: 0.1)
                                    : .easeInOut(duration: 2.0).repeatForever(autoreverses: true),
                                value: pulseScale
                            )

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
                                .animation(.linear(duration: 0.1), value: voiceManager.recordingDuration)
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
                    .task {
                        // 1.5초 후 플레이스홀더 페이드 아웃 → 마이크 버튼만 남김 (Zero Clutter)
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        withAnimation(.easeOut(duration: 0.8)) {
                            showPlaceholder = false
                        }
                    }

                    // ── 녹음 타이머 + 침묵 카운트다운 ──
                    if voiceManager.isListening {
                        VStack(spacing: 6) {
                            Text(formatDuration(voiceManager.recordingDuration))
                                .font(.system(size: 16, weight: .medium, design: .monospaced))
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.6))

                            // 침묵 카운트다운 표시
                            if voiceManager.silenceCountdown > 0 {
                                Text("\(L.voice.silenceCountdown) \(voiceManager.silenceCountdown)...")
                                    .font(.system(size: 13, weight: .semibold))
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
                                .transition(.scale.combined(with: .opacity))
                        } else if cloudLLM.isProcessing || voiceManager.isProcessing {
                            Text(L.voiceAnalyzing)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                        } else if voiceManager.isListening && !voiceManager.recognizedText.isEmpty {
                            // 실시간 텍스트 + 블링킹 커서
                            HStack(spacing: 0) {
                                Text(voiceManager.recognizedText)
                                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                                Text("|")
                                    .foregroundColor(DesignSystem.Colors.primary)
                                    .opacity(cursorVisible ? 1.0 : 0.0)
                                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: cursorVisible)
                                    .onAppear { cursorVisible.toggle() }
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
                                    .opacity(showPlaceholder ? 1.0 : 0.0)

                                if !hasSeenVoiceOnboarding {
                                    Text(L.voice.guideHint)
                                        .font(DesignSystem.Typography.labelSm)
                                        .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.4))
                                        .opacity(showPlaceholder ? 1.0 : 0.0)
                                }
                            }
                        }
                    }
                    .font(DesignSystem.Typography.titleSm)
                    .tracking(-0.5)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .animation(.easeInOut, value: voiceManager.recognizedText)
                    .animation(.easeInOut, value: voiceManager.isListening)
                    .animation(.easeInOut, value: voiceManager.isProcessing || cloudLLM.isProcessing)
                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: showSuccessCheck)
                }

                Spacer()
                Spacer(minLength: 120)
                } // end if-else showTextInput
            }

            // ── 확인 카드 오버레이 ──
            if showConfirmation {
                ConfirmationCardOverlay(
                    tasks: $pendingTasks,
                    onConfirm: { confirmPendingTasks() },
                    onCancel: { cancelPendingTasks() }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // ── 에러 토스트 ──
            if showErrorToast {
                VStack {
                    Spacer()

                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.white.opacity(0.9))

                        Text(errorToastMessage)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)

                        Spacer()

                        Button(action: {
                            withAnimation(.easeOut(duration: 0.2)) {
                                showErrorToast = false
                            }
                            handleMicTap()
                        }) {
                            Text(L.voice.tryAgain)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(DesignSystem.Colors.primaryFixedDim)
                        }
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
        }
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
                        pendingTasks = parsedTasks
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                            showConfirmation = true
                        }
                    } else {
                        taskManager.process(intents: parsedTasks)
                        showSuccessCheck = true
                        Haptic.notification(.success)
                    }
                }

                if !confirmBeforeSave {
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
        showPlaceholder = true
        Haptic.impact(.medium)
        voiceManager.toggleListening()
    }

    // MARK: - Confirmation Actions
    private func confirmPendingTasks() {
        taskManager.process(intents: pendingTasks)
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
                showPlaceholder = true
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.8)) {
                    showPlaceholder = false
                }
            }
        }
    }

    private func cancelPendingTasks() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            showConfirmation = false
            pendingTasks = []
            showPlaceholder = true
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
                            pendingTasks = parsedTasks
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                showConfirmation = true
                            }
                        } else {
                            // 바로 저장 (기존 동작)
                            taskManager.process(intents: parsedTasks)
                            showSuccessCheck = true
                            Haptic.notification(.success)
                        }
                    }

                    if !confirmBeforeSave {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        await MainActor.run {
                            showSuccessCheck = false
                            showPlaceholder = true
                        }
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        await MainActor.run {
                            withAnimation(.easeOut(duration: 0.8)) {
                                showPlaceholder = false
                            }
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

// MARK: - Confirmation Card Overlay
struct ConfirmationCardOverlay: View {
    @Binding var tasks: [ParsedTask]
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack {
            Spacer()

            VStack(spacing: 16) {
                // 태스크 미리보기 카드
                ForEach(tasks) { task in
                    HStack(spacing: 14) {
                        // 액션 아이콘
                        Image(systemName: task.action == "delete" ? "trash.circle.fill" : "plus.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(task.action == "delete" ? .red.opacity(0.8) : DesignSystem.Colors.tertiary)

                        VStack(alignment: .leading, spacing: 3) {
                            // 액션 라벨
                            Text(task.action == "delete" ? L.voice.confirmDelete : L.voice.confirmAdd)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))

                            // 태스크 이름
                            Text(task.task)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)

                            // 시간 + 카테고리
                            HStack(spacing: 8) {
                                if let time = task.time, !time.isEmpty {
                                    HStack(spacing: 3) {
                                        Image(systemName: "clock")
                                            .font(.system(size: 11))
                                        Text(time)
                                    }
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(DesignSystem.Colors.primary)
                                }

                                Text(task.category == "Appointment" ? L.voice.confirmAppointment : L.voice.confirmRoutine)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.4))
                            }
                        }

                        Spacer()

                        // 개별 항목 삭제 버튼
                        if tasks.count > 1 {
                            Button(action: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    tasks.removeAll { $0.id == task.id }
                                }
                                Haptic.impact(.light)
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.3))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(DesignSystem.Colors.surfaceContainerLow)
                    )
                }

                // 확인/취소 버튼
                HStack(spacing: 12) {
                    Button(action: onCancel) {
                        Text(L.voice.confirmCancel)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(DesignSystem.Colors.onSurfaceVariant.opacity(0.2), lineWidth: 1)
                            )
                    }

                    Button(action: onConfirm) {
                        Text(L.voice.confirmButton)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(DesignSystem.Gradients.primaryCTA)
                            )
                    }
                }
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(DesignSystem.Colors.background)
                    .shadow(color: .black.opacity(0.15), radius: 20, y: -5)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 140)
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

                Text(L.voice.guideTitle)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
            }
            .padding(.top, 24)

            VStack(spacing: 16) {
                ForEach(Array(examples.enumerated()), id: \.offset) { _, example in
                    HStack(spacing: 16) {
                        Image(systemName: example.icon)
                            .font(.system(size: 24))
                            .foregroundColor(example.color)
                            .frame(width: 36)

                        Text(example.text)
                            .font(.system(size: 17, weight: .medium))
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

// MARK: - Preview
struct HomeVoiceInterfaceView_Previews: PreviewProvider {
    static var previews: some View {
        HomeVoiceInterfaceView()
            .environmentObject(CloudLLMManager())
            .environmentObject(TaskManager())
            .environmentObject(AuthManager())
            .environmentObject(NetworkMonitor.shared)
    }
}
