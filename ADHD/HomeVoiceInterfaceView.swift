import SwiftUI
import Combine

// MARK: - Home Voice Interface View
struct HomeVoiceInterfaceView: View {
    @EnvironmentObject var cloudLLM: CloudLLMManager
    @EnvironmentObject var taskManager: TaskManager
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var networkMonitor: NetworkMonitor
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    
    @ObservedObject var langManager = LocalizationManager.shared
    @StateObject private var voiceManager = VoiceInputManager()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isBreathing = false
    @State private var showSuccessCheck = false
    @State private var showSettings = false

    @State private var showVoiceGuide = false
    @State private var shakeOffset: CGFloat = 0
    @State private var showErrorToast = false
    @State private var errorToastMessage = ""
    @State private var errorToastOpensSettings = false
    /// '설정 열기'로 설정 앱에 다녀오는 중인지 (돌아오면 권한을 다시 확인)
    @State private var awaitingSettingsReturn = false
    /// 오류 토스트 버튼이 할 일. 오류마다 맞는 동작을 함께 넘기고, 없으면 버튼을 두지 않습니다.
    @State private var errorToastRetry: ToastRetryAction = .none
    /// 누른 채 말하기에서 손가락이 버튼 위에 있는지. 탭 넘김 등으로 제스처가 취소돼도 false로 돌아옵니다.
    @GestureState private var isHoldingMic = false
    @State private var errorToastStyle: HomeToastStyle = .error
    @State private var errorToastID = UUID()
    @AppStorage("hasSeenVoiceOnboarding") private var hasSeenVoiceOnboarding = false
    @State private var confirmBeforeSave = true

    // Confirmation card state
    @State private var pendingTasks: [PendingLLMCall] = []
    @State private var pendingSubmittedDraft: String?
    @State private var pendingAnalysisContext: TaskAnalysisContext?
    @State private var showConfirmation = false
    @State private var editingTask: PendingLLMCall? = nil
    
    // Binding to pass modal state up to parent (MainTabView)
    @Binding var activeTab: TabSelection
    @Binding var isModalVisible: Bool
    @State private var showPaywall = false
    @State private var showAIConsent = false
    /// 동의 시트에서 동의하고 닫히면 보내려던 글을 바로 이어서 정리합니다.
    @State private var resumeAnalysisAfterConsent = false
    /// AI가 되물은 뒤 다시 말하면, 새 말을 원래 초안 뒤에 붙여 보냅니다("오후" 같은 짧은 답만으로는 뜻이 없으므로).
    @State private var appendNextSpeech = false

    // Text input state
    @State private var showTextInput = false
    @State private var textInputValue = ""
    @State private var activeAnalysisID: UUID?
    @State private var analysisTask: Task<Void, Never>?
    @State private var successPresentationID: UUID?
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
                        let shouldShowTextInput = !showTextInput
                        if shouldShowTextInput {
                            preserveSpeechDraftAndStopListening()
                        }
                        let anim: Animation? = reduceMotion ? .none : .spring(response: 0.3, dampingFraction: 0.8)
                        withAnimation(anim) {
                            showTextInput = shouldShowTextInput
                            if showTextInput {
                                isTextInputFocused = !voiceManager.isProcessing
                            }
                        }
                    }) {
                        Image(systemName: showTextInput ? "mic.fill" : "keyboard")
                            .font(.title3.weight(.medium))
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(showTextInput
                        ? L.t("Switch to voice input", "음성 입력으로 전환", "音声入力に切り替え")
                        : L.t("Switch to text input", "키보드 입력으로 전환", "キーボード入力に切り替え"))

                    // F2/D7: 음성 가이드 상시 진입점
                    Button(action: { showVoiceGuide = true }) {
                        Image(systemName: "questionmark.circle")
                            .font(.title3.weight(.medium))
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(L.voice.guideTitle)

                    Spacer()

                    if !subscriptionManager.isPremium {
                        Button(action: { showPaywall = true }) {
                            HStack(spacing: 4) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("\(subscriptionManager.remainingAIUsage)/\(SubscriptionManager.freeAILimit)")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                            }
                            .foregroundColor(subscriptionManager.canUseAI ? DesignSystem.Colors.primary : DesignSystem.Colors.error)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill((subscriptionManager.canUseAI
                                           ? DesignSystem.Colors.primary
                                           : DesignSystem.Colors.error).opacity(0.1))
                            )
                        }
                    }

                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape")
                            .font(.title3.weight(.medium))
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(L.settings.title)
                    .accessibilityHint(L.t("Double tap to open settings", "설정을 열려면 이중 탭하세요", "設定を開くにはダブルタップ"))
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

                        HStack(alignment: .bottom, spacing: 12) {
                            // 받아쓴 초안(150~250자)이 한눈에 보이도록 여러 줄로 늘어납니다.
                            HStack(alignment: .top, spacing: 8) {
                                TextField(L.voice.textInputPlaceholder, text: $textInputValue, axis: .vertical)
                                    .font(.body.weight(.medium))
                                    .lineLimit(1...6)
                                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                                    .focused($isTextInputFocused)
                                    .disabled(voiceManager.isProcessing)
                                    .submitLabel(.send)
                                    .onChange(of: textInputValue) { _, newValue in
                                        // 여러 줄 입력칸에서는 return이 줄바꿈이 되므로, return을 보내기로 바꿉니다.
                                        guard newValue.contains("\n") else { return }
                                        textInputValue = newValue.replacingOccurrences(of: "\n", with: " ")
                                            .trimmingCharacters(in: .whitespaces)
                                        if newValue.hasSuffix("\n") { sendTextInput() }
                                    }

                                if !textInputValue.isEmpty && !voiceManager.isProcessing && activeAnalysisID == nil {
                                    Button {
                                        textInputValue = ""
                                        Haptic.impact(.light)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.body)
                                            .foregroundColor(DesignSystem.Colors.onSurfaceMeta)
                                            .frame(minWidth: 32, minHeight: 32)
                                            .contentShape(Rectangle())
                                    }
                                    .accessibilityLabel(L.voice.clearDraft)
                                }
                            }
                            .padding(.leading, 16)
                            .padding(.trailing, 8)
                            .padding(.vertical, 10)
                            .frame(minHeight: 50)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(DesignSystem.Colors.surfaceContainerLow)
                            )

                            Button(action: { sendTextInput() }) {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.title.weight(.medium))
                                    .foregroundColor(textInputValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? DesignSystem.Colors.onSurfaceVariant.opacity(0.4)
                                        : DesignSystem.Colors.primary)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .disabled(
                                textInputValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || activeAnalysisID != nil
                                    || cloudLLM.isProcessing
                                    || voiceManager.isProcessing
                            )
                            .accessibilityLabel(L.voice.analyzeDraft)
                            .accessibilityHint(L.voice.analyzeDraftHint)
                        }
                        .padding(.horizontal, 24)

                        // 서버 한도(1,000자)에 가까워질 때만 글자 수를 보여 줍니다.
                        if Self.showsDraftLength(textInputValue) {
                            Text("\(textInputValue.utf16.count)/\(Self.maxDraftLength)")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(textInputValue.utf16.count > Self.maxDraftLength
                                    ? DesignSystem.Colors.error
                                    : DesignSystem.Colors.onSurfaceMeta)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .padding(.horizontal, 32)
                        }

                        if activeAnalysisID != nil {
                            analyzingStatus
                        } else if voiceManager.isProcessing {
                            Text(L.voice.preparingDraft)
                                .font(DesignSystem.Typography.bodyMd)
                                .foregroundColor(DesignSystem.Colors.onSurfaceMeta)
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
                        // SFSpeechRecognizer + AVAudioSession 사전 초기화 (첫 탭 렉 방지)
                        if !MoraApp.presentationDemoMode {
                            voiceManager.warmUp()
                        }
                        // D21: 온보딩 스킵자에게만 가이드 자동 1회 (완료자는 플래그가 이미 true)
                        if !hasSeenVoiceOnboarding && !MoraApp.presentationDemoMode {
                            showVoiceGuide = true
                        }
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
                                .accessibilityLabel(L.t("Task saved successfully", "일정을 저장했어요", "タスクを保存しました"))
                        } else if activeAnalysisID != nil {
                            analyzingStatus
                        } else if voiceManager.isProcessing {
                            Text(L.voice.preparingDraft)
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
                        } else if !voiceManager.isListening,
                                  !textInputValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            // 분석이 실패했거나 AI가 되물었을 때 남은 초안. 누르면 입력창에서 고칩니다.
                            Button(action: editPendingDraft) {
                                VStack(spacing: 6) {
                                    Text(L.aiPrivacy.quoted(textInputValue))
                                        .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                                        .lineLimit(2)
                                    Text(L.voice.editDraft)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(DesignSystem.Colors.primary)
                                }
                            }
                            .buttonStyle(NoEffectButtonStyle())
                        } else if voiceManager.isListening {
                            Text(L.voiceListening)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                        } else {
                            Text(voiceManager.showPermissionReadyHint ? L.voice.permissionReadyHint : L.voicePlaceholder)
                                .foregroundColor(DesignSystem.Colors.primary)
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
                    // 바깥을 스쳐도 차감된 분석 결과가 사라지지 않도록 탭으로 닫지 않습니다(카드의 취소 버튼만 사용).
                    Rectangle()
                        .fill(.ultraThinMaterial.opacity(0.8))
                        .ignoresSafeArea()
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
                // VoiceOver가 확인 카드 뒤 홈 화면으로 넘어가지 않도록 모달로 알립니다.
                .accessibilityAddTraits(.isModal)
                .zIndex(20)
            }

            // ── 에러·안내 토스트 ──
            // 확인 카드 위에서도 보이고 눌리도록 카드(zIndex 20)보다 위에 둡니다.
            if showErrorToast {
                VStack {
                    Spacer()

                    HStack(spacing: 12) {
                        Image(systemName: errorToastStyle.icon)
                            .font(.body)
                            .foregroundColor(.white.opacity(0.9))
                            .accessibilityHidden(true)

                        Text(errorToastMessage)
                            .font(.footnote.weight(.medium))
                            .foregroundColor(.white)

                        Spacer()

                        // 확인 카드가 떠 있을 때 "다시 시도"는 새 분석을 시작하므로 보여주지 않습니다.
                        if errorToastOpensSettings || (errorToastRetry != .none && !showConfirmation) {
                            Button(action: {
                                withAnimation(reduceMotion ? .none : .easeOut(duration: 0.2)) {
                                    showErrorToast = false
                                }
                                if errorToastOpensSettings {
                                    awaitingSettingsReturn = true
                                    if let url = URL(string: UIApplication.openSettingsURLString) {
                                        UIApplication.shared.open(url)
                                    }
                                    return
                                }
                                switch errorToastRetry {
                                case .record:
                                    handleMicTap()
                                case .analyzeDraft:
                                    sendTextInput()
                                case .none:
                                    break
                                }
                            }) {
                                Text(errorToastOpensSettings ? L.voice.openSettings : L.voice.tryAgain)
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(DesignSystem.Colors.primaryFixedDim)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel(errorToastOpensSettings ? L.voice.openSettings : L.voice.tryAgain)
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
                    // 안내를 눌러 바로 닫을 수 있게 합니다 (VoiceOver는 두 손가락 문지르기로 닫기).
                    .contentShape(Rectangle())
                    .onTapGesture { dismissToast() }
                    .accessibilityAction(.escape) { dismissToast() }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .zIndex(30)
            }
        } // End main ZStack
        .edgesIgnoringSafeArea(.bottom)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(authManager)
                .environmentObject(taskManager)
                .environmentObject(subscriptionManager)
        }
        .sheet(isPresented: $showAIConsent, onDismiss: {
            guard resumeAnalysisAfterConsent else { return }
            resumeAnalysisAfterConsent = false
            sendTextInput()
        }) {
            AIDataConsentView(userID: authManager.accessState.accountUserID, draft: textInputValue,
                              onAllowed: { resumeAnalysisAfterConsent = true })
        }
        .onReceive(NotificationCenter.default.publisher(for: AIDataConsent.didChange)) { _ in
            if !AIDataConsent.isGranted(for: authManager.accessState.accountUserID) { cancelActiveAnalysis() }
        }
        .sheet(isPresented: $showPaywall) {
            NavigationView {
                PaywallView()
                    .environmentObject(subscriptionManager)
            }
        }
        .sheet(isPresented: $showVoiceGuide, onDismiss: {
            if !hasSeenVoiceOnboarding { hasSeenVoiceOnboarding = true }
        }) {
            VoiceGuideSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: voiceManager.lastError) { _, newError in
            if let error = newError {
                triggerErrorFeedback(
                    message: error.message,
                    openSettings: error.needsSettings,
                    retry: error.canRetryRecording ? .record : .none
                )
                voiceManager.lastError = nil
            }
        }
        .onChange(of: voiceManager.isProcessing) { _, isProcessing in
            if !isProcessing && showTextInput {
                isTextInputFocused = scenePhase == .active && activeTab == .voice
                    && !showSettings && !showPaywall && !showVoiceGuide && !showAIConsent
            }
        }
        .onChange(of: showConfirmation) { _, isVisible in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                isModalVisible = isVisible
            }
        }
        .onAppear {
            isModalVisible = showConfirmation
            loadConfirmBeforeSavePreference()
        }
        .onDisappear {
            preserveSpeechDraftAndStopListening()
            cancelActiveAnalysis()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                preserveSpeechDraftAndStopListening()
            }
            if newPhase == .active { subscriptionManager.refreshQuotaDisplay() }
            // 설정에서 켜고 돌아오면 안내 글 없이 오류 토스트를 거두고 바로 말할 수 있게 합니다.
            if newPhase == .active, awaitingSettingsReturn || (showErrorToast && errorToastOpensSettings) {
                awaitingSettingsReturn = false
                if voiceManager.refreshPermissionsAfterSettings() {
                    withAnimation(.easeOut(duration: 0.2)) { showErrorToast = false }
                    Haptic.notification(.success)
                }
            }
            // 제어 센터·알림 센터를 잠깐 내리는 비활성 상태에서는 분석을 이어갑니다.
            // 서버는 이미 요청을 처리·차감하고 있으므로, 앱을 실제로 떠날 때만 취소합니다.
            if newPhase == .background {
                cancelActiveAnalysis()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
                .receive(on: DispatchQueue.main)
        ) { _ in
            subscriptionManager.refreshQuotaDisplay()
        }
        .onChange(of: activeTab) { _, newTab in
            if newTab != .voice {
                preserveSpeechDraftAndStopListening()
                cancelActiveAnalysis()
            }
        }
        .onChange(of: showSettings) { _, isVisible in
            if isVisible {
                preserveSpeechDraftAndStopListening()
                cancelActiveAnalysis()
            } else {
                loadConfirmBeforeSavePreference()
            }
        }
        .onChange(of: authManager.accessState) { _, _ in
            if let context = pendingAnalysisContext, !canUseAnalysisContext(context) {
                cancelPendingTasks()
            }
            loadConfirmBeforeSavePreference()
        }
        .onChange(of: showPaywall) { _, isVisible in
            if isVisible {
                preserveSpeechDraftAndStopListening()
                cancelActiveAnalysis()
            }
        }
        .onChange(of: showVoiceGuide) { _, isVisible in
            if isVisible {
                preserveSpeechDraftAndStopListening()
                cancelActiveAnalysis()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .accountSessionSensitiveStateReset)
        ) { _ in
            cancelActiveAnalysis()
            voiceManager.discardAccountSensitiveState()
            textInputValue = ""
            pendingSubmittedDraft = nil
            pendingAnalysisContext = nil
            pendingTasks = []
            editingTask = nil
            showConfirmation = false
            showAIConsent = false
            resumeAnalysisAfterConsent = false
            appendNextSpeech = false
            showTextInput = false
            showErrorToast = false
            isTextInputFocused = false
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
                .foregroundColor(DesignSystem.Colors.onPrimary)
                .contentTransition(.symbolEffect(.replace))
        }

        if voiceManager.micMode == .holdToTalk {
            // Hold-to-Talk: 누르면 시작, 떼면 종료
            buttonContent
                .scaleEffect(voiceManager.isListening ? 0.93 : 1.0)
                .animation(.easeOut(duration: 0.2), value: voiceManager.isListening)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($isHoldingMic) { _, holding, _ in holding = true }
                        .onChanged { _ in
                            if !voiceManager.isListening
                                && activeAnalysisID == nil
                                && !cloudLLM.isProcessing
                                && !voiceManager.isProcessing {
                                handleMicTap()
                            }
                        }
                        .onEnded { _ in
                            if voiceManager.isListening {
                                voiceManager.stopListening()
                            }
                        }
                )
                // 손가락이 밀려 페이지 넘김이 제스처를 가져가면 onEnded가 오지 않으므로, 눌림이 풀리면 멈춥니다.
                .onChange(of: isHoldingMic) { _, holding in
                    if !holding && voiceManager.isListening {
                        voiceManager.stopListening()
                    }
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { handleMicTap() }
        } else {
            // Tap-to-Toggle (기본)
            Button(action: { handleMicTap() }) {
                buttonContent
            }
            .buttonStyle(SquishyButtonStyle())
            .disabled(activeAnalysisID != nil || cloudLLM.isProcessing || voiceManager.isProcessing)
        }
    }

    // MARK: - Text Input Handler
    private func sendTextInput() {
        let text = textInputValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, activeAnalysisID == nil,
              !cloudLLM.isProcessing, !voiceManager.isProcessing else { return }

        // 서버가 거절할 길이는 보내기 전에 알려 줍니다 (횟수 차감 없이).
        guard text.utf16.count <= Self.maxDraftLength else {
            triggerErrorFeedback(message: L.voice.errorTooLong)
            return
        }

        // 로그인은 없습니다. 보이지 않는 익명 계정이 아직 없으면 한 번만 만들어 보고, 그래도 안 되면 초안을 둔 채 짧게 알립니다.
        guard let accountID = authManager.accessState.accountUserID else {
            guard networkMonitor.isConnected else {
                networkMonitor.showOfflineBannerTemporarily()
                return
            }
            prepareAccountThenAnalyze()
            return
        }

        // 일정은 기기(또는 Apple 계정) 범위, AI 동의·횟수는 서버 계정(accountID)에 있습니다.
        guard taskManager.isReady, taskManager.modelContext != nil,
              let localUserID = authManager.accessState.localStorageUserID,
              let scope = AccountPreferences.activeScope,
              scope == AccountPreferences.scope(for: localUserID),
              let generation = AccountPreferences.sessionGeneration() else {
            triggerErrorFeedback(message: L.voice.errorApi)
            return
        }

        Haptic.impact(.medium)
        isTextInputFocused = false
        showSuccessCheck = false
        successPresentationID = nil

        let analysisID = UUID()
        activeAnalysisID = analysisID
        let context = TaskAnalysisContext(requestID: analysisID, language: langManager.currentLanguage.rawValue,
                                          accountScope: scope, accountGeneration: generation)

        analysisTask = Task {
            do {
                let result = try await TaskAnalysisRouter.analyze(
                    text: text, context: context,
                    localRulesEnabled: TaskAnalysisRollout.localRulesEnabled,
                    isCurrent: { activeAnalysisID == analysisID && canUseAnalysisContext(context) },
                    authorizeCloud: {
                        guard networkMonitor.isConnected else { throw TaskAnalysisError.offline }
                        guard AIDataConsent.isGranted(for: accountID) else { throw CloudLLMError.consentRequired }
                        guard subscriptionManager.canUseAI else { throw CloudLLMError.quotaExhausted }
                    },
                    cloud: { input, capturedContext in
                        let calls = try await cloudLLM.analyzeText(
                            text: input, accountID: accountID, context: capturedContext
                        )
                        return TaskAnalysisResult(calls: calls, source: .cloud, quota: cloudLLM.latestQuota)
                    }
                )
                let shouldHideSuccess = await MainActor.run {
                    guard activeAnalysisID == analysisID, canUseAnalysisContext(context) else { return false }
                    let shouldHide = handleSuccessfulAnalysis(result, submittedText: text, context: context)
                    activeAnalysisID = nil
                    analysisTask = nil
                    if shouldHide {
                        successPresentationID = analysisID
                    }
                    return shouldHide
                }

                if shouldHideSuccess {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await MainActor.run {
                        guard successPresentationID == analysisID else { return }
                        showSuccessCheck = false
                        successPresentationID = nil
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard activeAnalysisID == analysisID else { return }
                    activeAnalysisID = nil
                    analysisTask = nil
                }
            } catch TaskAnalysisError.offline {
                guard activeAnalysisID == analysisID else { return }
                activeAnalysisID = nil
                analysisTask = nil
                networkMonitor.showOfflineBannerTemporarily()
                triggerErrorFeedback(message: L.t(
                    "This draft needs an online analysis. Your text is saved here; you can also add it manually.",
                    "이 문장은 온라인 분석이 필요해요. 초안은 그대로 있으니 직접 추가할 수도 있어요.",
                    "この下書きにはオンライン解析が必要です。文章は残っているので手動でも追加できます。"))
            } catch CloudLLMError.consentRequired {
                await MainActor.run {
                    guard activeAnalysisID == analysisID else { return }
                    activeAnalysisID = nil
                    analysisTask = nil
                    showAIConsent = true
                }
            } catch CloudLLMError.quotaExhausted {
                await MainActor.run {
                    guard activeAnalysisID == analysisID else { return }
                    activeAnalysisID = nil
                    analysisTask = nil
                    showPaywall = true
                }
            } catch CloudLLMError.rateLimited {
                // 분당 제한·재시도 한도는 한도 소진이 아니므로 결제 화면 대신 잠시 뒤 다시 하도록 안내합니다.
                await MainActor.run {
                    guard activeAnalysisID == analysisID else { return }
                    activeAnalysisID = nil
                    analysisTask = nil
                    triggerErrorFeedback(message: L.voice.errorBusy)
                }
            } catch CloudLLMError.offline {
                await MainActor.run {
                    guard activeAnalysisID == analysisID else { return }
                    activeAnalysisID = nil
                    analysisTask = nil
                    triggerErrorFeedback(message: L.voice.errorNetwork, retry: .analyzeDraft)
                }
            } catch CloudLLMError.inputTooLong {
                await MainActor.run {
                    guard activeAnalysisID == analysisID else { return }
                    activeAnalysisID = nil
                    analysisTask = nil
                    triggerErrorFeedback(message: L.voice.errorTooLong)
                }
            } catch CloudLLMError.authenticationRequired {
                await MainActor.run {
                    guard activeAnalysisID == analysisID else { return }
                    activeAnalysisID = nil
                    analysisTask = nil
                    // 로그인 없이 쓰는 사용자에게는 로그인 안내 대신 잠시 뒤 다시 하라고만 알립니다.
                    triggerErrorFeedback(message: authManager.accessState.isGuest
                        ? L.voice.aiUnavailable : L.voice.errorSignInAgain)
                }
            } catch {
                print("ai_analysis_failed")
                await MainActor.run {
                    guard activeAnalysisID == analysisID else { return }
                    activeAnalysisID = nil
                    analysisTask = nil
                    triggerErrorFeedback(message: L.voice.errorApi, retry: .analyzeDraft)
                }
            }
        }
    }

    /// 익명 계정을 한 번 만들어 본 뒤 같은 초안으로 다시 분석을 시작합니다. 기다리는 동안은 분석 중 표시를 씁니다.
    private func prepareAccountThenAnalyze() {
        isTextInputFocused = false
        let attemptID = UUID()
        activeAnalysisID = attemptID
        analysisTask = Task {
            let isReady = await authManager.provisionAnonymousAccountIfNeeded()
            await MainActor.run {
                guard activeAnalysisID == attemptID else { return }
                activeAnalysisID = nil
                analysisTask = nil
                if isReady, authManager.accessState.accountUserID != nil {
                    sendTextInput()
                } else {
                    triggerErrorFeedback(message: L.voice.aiUnavailable)
                }
            }
        }
    }

    private func canUseAnalysisContext(_ context: TaskAnalysisContext) -> Bool {
        guard let localUserID = authManager.accessState.localStorageUserID else { return false }
        return context.isCurrentAccount && context.accountScope == AccountPreferences.scope(for: localUserID)
            && context.timeZone == .current && taskManager.isReady && taskManager.modelContext != nil
    }

    /// 모든 엔진이 같은 확인·실행 경계로 합류합니다. 로컬 성공에는 서버 quota가 없습니다.
    @MainActor
    private func handleSuccessfulAnalysis(
        _ result: TaskAnalysisResult,
        submittedText: String,
        context: TaskAnalysisContext
    ) -> Bool {
        let parsedTasks = result.calls
        guard canUseAnalysisContext(context), LLMFunctionCall.isValidAnalysis(parsedTasks) else {
            triggerErrorFeedback(message: L.voice.errorApi)
            return false
        }

        // 성공 분석의 서버 원장 스냅샷만 UI에 반영합니다. 로컬 추정 차감은 권한 원천이 아닙니다.
        if result.source == .cloud, let quota = result.quota {
            subscriptionManager.applyServerQuota(quota)
        }

        // 되묻기·잡담은 저장이 아니므로 성공으로 세지 않고 초안도 그대로 둡니다.
        // 사용자는 남아 있는 초안을 고쳐 다시 보낼 수 있습니다.
        let actionCalls = parsedTasks.filter { !$0.isFeedbackOnly }
        guard !actionCalls.isEmpty else {
            let questions = parsedTasks.filter(\.isClarification).compactMap(\.feedbackMessage)
            if !questions.isEmpty {
                appendNextSpeech = true
                showInfoMessage(questions.joined(separator: "\n"))
            } else if let offTopic = parsedTasks.first(where: \.isOffTopic) {
                pendingSubmittedDraft = nil
                pendingTasks = [PendingLLMCall(call: offTopic)]
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    showConfirmation = true
                }
            }
            return false
        }

        let prepared = taskManager.preparePendingCalls(parsedTasks.map { PendingLLMCall(call: $0) })
        let mustConfirm = result.requiresPreview || confirmBeforeSave
            || prepared.contains(where: { $0.executionIssue == .ambiguousTarget })
            || LLMConfirmationPolicy.requiresExplicitConfirmation(for: parsedTasks)
        if mustConfirm {
            pendingSubmittedDraft = submittedText
            pendingAnalysisContext = context
            pendingTasks = prepared
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                showConfirmation = true
            }
            return false
        }

        pendingAnalysisContext = context

        // 바로 저장도 항목별 결과를 받아, 일부만 실패하면 실패한 항목만 확인 카드에 남깁니다.
        // 초안을 다시 분석하면 이미 저장된 항목이 중복으로 생기기 때문입니다.
        let result = taskManager.executeDetailed(
            pendingCalls: taskManager.preparePendingCalls(
                actionCalls.map { PendingLLMCall(call: $0) }
            )
        )
        let feedbackCards = parsedTasks.filter(\.isFeedbackOnly).map { PendingLLMCall(call: $0) }
        guard presentExecutionResult(
            result,
            submittedDraft: submittedText,
            feedbackCards: feedbackCards
        ) else { return false }

        let messages = parsedTasks.compactMap(\.feedbackMessage)
        if !messages.isEmpty {
            showInfoMessage(messages.joined(separator: "\n"))
        }
        return true
    }

    // MARK: - Mic Button Handler
    private func handleMicTap() {
        guard activeAnalysisID == nil, !cloudLLM.isProcessing,
              !voiceManager.isProcessing else { return }
        // 남아 있는 초안이 있어도 막지 않습니다. 새로 말하면 초안을 바꾸고(되물은 뒤면 이어 붙이고) 바로 분석합니다.
        showTextInput = false
        isTextInputFocused = false
        Haptic.impact(.medium)
        voiceManager.toggleListening()
    }

    // MARK: - Confirmation Actions
    private func confirmPendingTasks() {
        guard let context = pendingAnalysisContext, canUseAnalysisContext(context) else {
            cancelPendingTasks()
            triggerErrorFeedback(message: L.voice.reviewUpdatedPreview)
            return
        }
        guard !pendingTasks.contains(where: { $0.executionIssue == .ambiguousTarget }) else {
            triggerErrorFeedback(message: L.t("Choose which task to change.", "변경할 일정을 선택해 주세요.", "変更するタスクを選んでください。"))
            return
        }
        // 시간은 비워 둘 수 있습니다(서버도 말하지 않은 시간은 null로 보냅니다).
        // 날짜 없는 플래너 일정만 오늘로 맞춘 편집 폼을 열어 날짜를 확인받습니다.
        if let undatedAppointment = pendingTasks.first(where: { task in
            guard case .addSingleTask(let params) = task.call else { return false }
            return params.category == "Appointment"
                && (params.date ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }) {
            withAnimation(.spring()) {
                self.editingTask = undatedAppointment
            }
            showInfoMessage(L.voice.errorMissingDate)
            return
        }

        // 카드 편집으로 승인 대상이 무효화됐다면 최신 UUID/상태로 미리보기만 갱신합니다.
        // 이 탭에서는 실행하지 않아 사용자가 바뀐 범위와 개수를 한 번 더 확인할 수 있습니다.
        if pendingTasks.contains(where: {
            $0.call.requiresPreparedTargets && $0.targetSnapshots == nil
        }) {
            pendingTasks = taskManager.preparePendingCalls(pendingTasks).map { pending in
                var refreshed = pending
                refreshed.requiresReconfirmation = true
                return refreshed
            }
            triggerErrorFeedback(message: L.voice.reviewUpdatedPreview)
            return
        }

        // 되묻기·잡담 카드는 보여주기만 하고 실행하지 않습니다.
        let actionTasks = pendingTasks.filter { !$0.call.isFeedbackOnly }
        guard !actionTasks.isEmpty else {
            cancelPendingTasks()
            return
        }

        // 알림 강도와 승인 시점 대상 스냅샷을 포함하여 항목별로 실행합니다.
        let result = taskManager.executeDetailed(
            pendingCalls: actionTasks,
            explicitlyConfirmed: true
        )

        guard presentExecutionResult(result, submittedDraft: pendingSubmittedDraft) else { return }
        scheduleSuccessCheckDismiss()
    }

    /// 항목별 실행 결과를 화면에 반영합니다. 모두 저장됐으면 true입니다.
    /// 하나라도 저장됐다면 초안을 비워 같은 내용을 다시 분석해 중복 저장하지 않게 하고,
    /// 실패한 항목만 확인 카드에 남겨 다시 분석하지 않고 고칠 수 있게 합니다.
    @MainActor
    private func presentExecutionResult(
        _ result: LLMExecutionBatchResult,
        submittedDraft: String?,
        feedbackCards: [PendingLLMCall] = []
    ) -> Bool {
        editingTask = nil
        if result.hasAnySuccess {
            clearDraftIfUnchanged(submittedDraft)
            pendingSubmittedDraft = nil
        } else {
            pendingSubmittedDraft = submittedDraft
        }

        guard result.allSucceeded else {
            pendingTasks = result.remainingCalls + feedbackCards
            if !showConfirmation {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    showConfirmation = true
                }
            }
            if result.hasAnySuccess {
                Haptic.notification(.success)
                triggerErrorFeedback(message: L.voice.partialSaveResult)
            } else {
                triggerErrorFeedback(message: Self.failureMessage(for: result))
            }
            return false
        }

        pendingTasks = []
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            showConfirmation = false
            showSuccessCheck = true
        }
        Haptic.notification(.success)
        return true
    }

    private static func failureMessage(for result: LLMExecutionBatchResult) -> String {
        if result.items.contains(where: {
            $0.issue == .staleTarget || $0.issue == .previewRequired
        }) {
            return L.voice.reviewUpdatedPreview
        }
        if result.items.contains(where: { $0.issue == .noMatchingTarget }) {
            return L.voice.noMatchingTarget
        }
        if result.items.contains(where: {
            $0.issue == .persistenceFailed
                || $0.issue == .notExecutedAfterStoreFailure
        }) {
            return L.voice.saveFailedPreserved
        }
        return L.voice.errorApi
    }

    @MainActor
    private func scheduleSuccessCheckDismiss() {
        let successID = UUID()
        successPresentationID = successID
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run {
                guard successPresentationID == successID else { return }
                showSuccessCheck = false
                successPresentationID = nil
            }
        }
    }

    private func cancelPendingTasks() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            showConfirmation = false
            pendingTasks = []
            pendingSubmittedDraft = nil
            pendingAnalysisContext = nil
        }
    }

    @MainActor
    private func clearDraftIfUnchanged(_ submittedDraft: String?) {
        guard let submittedDraft,
              textInputValue.trimmingCharacters(in: .whitespacesAndNewlines) == submittedDraft else {
            return
        }
        textInputValue = ""
    }

    // MARK: - Error Feedback
    /// 실패를 알립니다. retry가 있을 때만 "다시 시도" 버튼을 두고, 그 오류에 맞는 동작을 합니다.
    /// (입력창 상태로 동작을 추측하면 안내만 보여야 할 때 초안이 AI로 전송될 수 있습니다.)
    private func triggerErrorFeedback(
        message: String,
        openSettings: Bool = false,
        retry: ToastRetryAction = .none
    ) {
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

        presentToast(
            message: message,
            style: .error,
            openSettings: openSettings,
            retry: retry,
            duration: openSettings ? 8 : 4
        )
    }

    /// 실패가 아닌 안내(되묻기 질문 등)를 홈 화면 토스트로 차분하게 보여줍니다.
    /// 흔들림·오류 햅틱 없이, 읽을 시간을 조금 더 둡니다.
    private func showInfoMessage(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Haptic.impact(.light)
        presentToast(
            message: trimmed,
            style: .notice,
            openSettings: false,
            retry: .none,
            duration: 8
        )
    }

    private func presentToast(
        message: String,
        style: HomeToastStyle,
        openSettings: Bool,
        retry: ToastRetryAction,
        duration: TimeInterval
    ) {
        errorToastMessage = message
        errorToastStyle = style
        errorToastOpensSettings = openSettings
        errorToastRetry = retry
        let toastID = UUID()
        errorToastID = toastID
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            showErrorToast = true
        }
        // VoiceOver 사용자는 화면 아래 토스트를 놓치기 쉬우므로 내용을 바로 읽어줍니다.
        AccessibilityNotification.Announcement(message).post()
        // 권한 안내도 잠시 뒤 스스로 사라집니다(글로 입력하려는 사람 화면에 계속 남지 않게).
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard errorToastID == toastID else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                showErrorToast = false
            }
        }
    }

    private func dismissToast() {
        withAnimation(reduceMotion ? .none : .easeOut(duration: 0.2)) {
            showErrorToast = false
        }
    }

    /// 분석 중 표시: 진행 표시와 취소 버튼 (기다리는 동안 그만둘 수 있게)
    private var analyzingStatus: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                ProgressView()
                    .tint(DesignSystem.Colors.primary)
                Text(L.voiceAnalyzing)
                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
            }
            Button {
                cancelActiveAnalysis()
                Haptic.impact(.light)
            } label: {
                Text(L.voice.cancel)
                    .font(.callout.weight(.medium))
                    .foregroundColor(DesignSystem.Colors.primary)
                    .frame(minWidth: 88, minHeight: 44)
                    .contentShape(Rectangle())
            }
        }
    }

    /// 서버가 받는 초안 최대 길이 (analyze-task의 text.length, UTF-16 기준)
    static let maxDraftLength = 1000

    /// 한도의 80%를 넘으면 글자 수를 보여 줍니다.
    static func showsDraftLength(_ text: String) -> Bool {
        text.utf16.count > maxDraftLength * 4 / 5
    }

    /// 기기 설정이므로 로컬 범위(익명 계정이면 기기 범위)에서 읽습니다.
    private func loadConfirmBeforeSavePreference() {
        guard let userID = authManager.accessState.localStorageUserID else {
            confirmBeforeSave = true
            return
        }
        confirmBeforeSave = AccountPreferences.bool(
            .confirmBeforeSave,
            default: true,
            for: userID
        )
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
            publishSpeechDraft(text, using: voiceManager, analyzeNow: true)
        }
    }

    /// 말이 끝나면(analyzeNow) 키보드 없이 바로 분석합니다. 확인은 저장 전 확인 카드가 맡습니다.
    /// 녹음 중 키보드 버튼을 눌렀을 때만 초안을 입력창에 옮겨 고칠 수 있게 합니다.
    @MainActor
    private func publishSpeechDraft(_ text: String, using manager: VoiceInputManager, analyzeNow: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            manager.isProcessing = false
            manager.lastError = .emptyTranscription
            return
        }

        let canAnalyzeNow = analyzeNow && !showTextInput
            && scenePhase == .active
            && activeTab == .voice
            && !showSettings
            && !showPaywall
            && !showVoiceGuide
        if canAnalyzeNow {
            let previous = textInputValue.trimmingCharacters(in: .whitespacesAndNewlines)
            textInputValue = appendNextSpeech && !previous.isEmpty ? previous + " " + trimmed : trimmed
            appendNextSpeech = false
            // 이 콜백 동안 VoiceInputManager는 아직 처리 중이라 분석이 막히므로, 처리가 끝난 다음 차례에 보냅니다.
            DispatchQueue.main.async { sendTextInput() }
            return
        }

        if textInputValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            textInputValue = text
        }
        showTextInput = true
        isTextInputFocused = scenePhase == .active
            && activeTab == .voice
            && !showSettings
            && !showPaywall
            && !showVoiceGuide
    }

    @MainActor
    private func editPendingDraft() {
        appendNextSpeech = false
        let anim: Animation? = reduceMotion ? .none : .spring(response: 0.3, dampingFraction: 0.8)
        withAnimation(anim) {
            showTextInput = true
            isTextInputFocused = true
        }
    }

    @MainActor
    private func preserveSpeechDraftAndStopListening() {
        let currentText = voiceManager.recognizedText
        if voiceManager.isListening {
            voiceManager.stopListening()
        } else if voiceManager.isProcessing {
            return
        } else if !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            publishSpeechDraft(currentText, using: voiceManager)
        }
    }

    @MainActor
    private func cancelActiveAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        activeAnalysisID = nil
        successPresentationID = nil
        showSuccessCheck = false
    }
}

/// 오류 토스트의 '다시 시도'가 할 일
enum ToastRetryAction {
    case none
    /// 다시 녹음 (받아쓰기 실패)
    case record
    /// 지금 초안을 다시 분석 (연결·서버 문제)
    case analyzeDraft
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

// MARK: - Home Toast Style
/// 홈 화면 토스트 종류. 실패와 안내(되묻기 등)를 아이콘으로 구분합니다.
private enum HomeToastStyle {
    case error
    case notice

    var icon: String {
        switch self {
        case .error: return "exclamationmark.circle.fill"
        case .notice: return "text.bubble.fill"
        }
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
    @State private var editHasNoTime = false
    /// 편집을 시작할 때의 값. 수정 카드는 이 값과 달라진 항목만 반영합니다.
    @State private var editBaseline: PendingCallEditDraft?
    @State private var loadedEditID: UUID?

    var onConfirm: () -> Void
    var onCancel: () -> Void

    // OOV(재치 있는 메시지)만 있는 카드인지 확인 — 실행할 항목이 섞여 있으면 일반 확인 카드로 보여줍니다.
    private var isOffTopic: Bool {
        !tasks.isEmpty && tasks.allSatisfy { $0.call.isOffTopic }
    }

    /// 편집 중인 카드 위치. 폼 값이 그 카드로 채워진 뒤에만 편집 화면을 보여줍니다.
    private var editingIndex: Int? {
        guard let editingTask, loadedEditID == editingTask.id else { return nil }
        return tasks.firstIndex(where: { $0.id == editingTask.id })
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                let titleText = editingTask == nil ? (isOffTopic ? L.voice.offTopicTitle : L.voice.confirmTitle) : L.voice.editTaskTitle
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
                .accessibilityLabel(L.t("Close", "닫기", "閉じる"))
                .accessibilityHint(L.t("Double tap to cancel", "취소하려면 이중 탭하세요", "キャンセルするにはダブルタップ"))
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 16)

            // 화면에 들어가면 내용 높이에 맞추고, 항목이 많거나 글씨가 크면 스크롤합니다.
            ViewThatFits(in: .vertical) {
                cardContent
                ScrollView(showsIndicators: false) {
                    cardContent
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            if editingIndex == nil {
                // The "Satisfying Hub" Confirm Button
                // 스크롤 밖에 두어 항목 수·글씨 크기와 상관없이 항상 누를 수 있게 합니다.
                Button(action: isOffTopic ? onCancel : onConfirm) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                        Text(isOffTopic ? L.voice.askAgain : L.voice.confirmButton)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(SatisfyingButtonStyle(color: DesignSystem.Colors.primary))
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
        }
        .frame(maxWidth: 340) // slightly narrower
        // The modal background & glow
        .glassStyle(cornerRadius: 32)
        // Replaced muddy black shadow with a soft themed glow
        .shadow(color: DesignSystem.Colors.primary.opacity(0.15), radius: 40, x: 0, y: 15)
        .shadow(color: DesignSystem.Colors.onSurfaceVariant.opacity(0.05), radius: 10, x: 0, y: 5)
        .padding(.horizontal, 24)
        .padding(.vertical, 40)
        .onAppear { loadEditFields() }
        .onChange(of: editingTask?.id) { _, _ in loadEditFields() }
    }

    @ViewBuilder
    private var cardContent: some View {
        if let index = editingIndex, let baseline = editBaseline {
            editForm(index: index, baseline: baseline)
        } else {
            taskList
        }
    }

    // MARK: Inline Edit Mode (Bubbles Style)
    private func editForm(index: Int, baseline: PendingCallEditDraft) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 16) {
                if baseline.scope == .allFields {
                    // Category Selection (Segmented)
                    Picker(L.voice.fieldCategory, selection: $editCategory) {
                        Text(L.voice.confirmAppointment).tag("Appointment")
                        Text(L.voice.confirmRoutine).tag("Routine")
                    }
                    .pickerStyle(.segmented)
                }

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

                // 삭제·완료 카드는 찾을 대상 이름만 고칠 수 있어 날짜·시간 칸을 두지 않습니다.
                if baseline.scope == .allFields {
                    timeBubble
                }
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
                    saveEdit(at: index, baseline: baseline)
                }
                .buttonStyle(SatisfyingButtonStyle(color: DesignSystem.Colors.primary))
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }

    // Time Bubble (Minimalist Picker)
    private var timeBubble: some View {
        let isAppointment = editCategory == "Appointment"
        let components: DatePickerComponents = isAppointment
            ? (editHasNoTime ? [.date] : [.date, .hourAndMinute])
            : (editHasNoTime ? [] : [.hourAndMinute])

        return VStack(spacing: 12) {
            if !components.isEmpty {
                HStack {
                    Text(isAppointment && editHasNoTime ? L.voice.fieldDate : L.voice.fieldTime)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.7))
                    Spacer()
                    DatePicker("", selection: $editDateTime, displayedComponents: components)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                }
            }

            // 말하지 않은 시간은 비워 둘 수 있습니다. 켜 두면 시간 없이 저장합니다.
            Toggle(isOn: $editHasNoTime) {
                Text(L.voice.noTime)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.7))
            }
            .tint(DesignSystem.Colors.primary)
        }
        .padding(14)
        .background(Color(UIColor.systemBackground).opacity(0.6))
        .cornerRadius(12)
    }

    // MARK: List Mode
    private var taskList: some View {
        VStack(spacing: 14) {
            ForEach(tasks) { task in
                taskCard(task)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
    }

    private func taskCard(_ task: PendingLLMCall) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !task.call.isOffTopic {
                HStack {
                    if task.call.isClarification {
                        // 되묻기는 일정이 아니므로 루틴·플래너 대신 질문으로 표시합니다.
                        Label(task.uiActionLabel, systemImage: "questionmark.circle")
                            .font(.caption.weight(.bold))
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(DesignSystem.Colors.onSurfaceVariant.opacity(0.1))
                            .cornerRadius(8)
                    } else {
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
                    }

                    Spacer()

                    if task.uiAction == "delete" || task.uiAction == "update" {
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

                    // Urgency Toggle (Strong/Weak) — 새로 추가하는 항목에만 적용됩니다.
                    if task.uiAction == "add" {
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
                }
                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.6))
            }

            if task.call.requiresPreparedTargets {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "scope")
                            .accessibilityHidden(true)
                        Text(L.voice.affectedCount(task.targetSnapshots?.count ?? 0))
                        if task.requiresReconfirmation {
                            Text("• \(L.voice.reviewUpdatedPreview)")
                        }
                    }
                    if let selected = task.targetSnapshots?.first,
                       task.targetSnapshots?.count == 1 {
                        HStack {
                            Text(selected.task)
                            if let date = selected.date {
                                Text(date, format: .dateTime.year().month().day())
                            }
                            if let time = selected.time { Text(time) }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    // 개수만으로는 무엇이 바뀌는지 알기 어려워 실제 대상 이름을 함께 보여줍니다.
                    if let names = task.targetNamesSummary {
                        Text(names)
                            .lineLimit(2)
                    }
                }
                .font(.caption2.weight(.semibold))
                .foregroundColor(
                    task.requiresReconfirmation
                        ? .orange
                        : DesignSystem.Colors.onSurfaceVariant.opacity(0.6)
                )
            }

            if task.executionIssue == .ambiguousTarget {
                Text(L.t("Choose which task to change", "변경할 일정을 선택해 주세요", "変更するタスクを選んでください"))
                    .font(.subheadline.weight(.semibold))
                ForEach(task.targetCandidates, id: \.id) { candidate in
                    Button {
                        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
                        tasks[index].selectTarget(id: candidate.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(candidate.task)
                            HStack {
                                if let date = candidate.date {
                                    Text(date, format: .dateTime.year().month().day())
                                }
                                if let time = candidate.time { Text(time) }
                                Text(candidate.category == "Routine"
                                     ? L.t("Routine", "루틴", "ルーティン")
                                     : L.t("Appointment", "일정", "予定"))
                            }
                            .font(.caption)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
            }

            // 실패해서 남은 카드는 이유를 카드 안에서 바로 보여줍니다.
            if let issueMessage = task.inlineIssueMessage {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .accessibilityHidden(true)
                    Text(issueMessage)
                }
                .font(.caption2.weight(.semibold))
                .foregroundColor(.orange)
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
            guard task.executionIssue != .ambiguousTarget else { return }
            switch task.call {
            case .addSingleTask, .updateTask, .deleteSpecificTask, .markTaskComplete:
                withAnimation(.spring()) { editingTask = task }
            default:
                break
            }
        }
    }

    // MARK: Edit State
    /// 편집할 카드의 현재 값으로 폼을 채웁니다. 날짜가 없는 플래너 일정은 오늘이 기본값입니다.
    private func loadEditFields() {
        guard let editingTask,
              let current = tasks.first(where: { $0.id == editingTask.id }),
              let draft = current.makeEditDraft() else {
            editBaseline = nil
            loadedEditID = nil
            return
        }

        editName = draft.name
        editCategory = draft.category
        editHasNoTime = draft.time == nil

        var initialDate = draft.date.flatMap { StoredTaskFormat.date.date(from: $0) } ?? Date()
        if let time = draft.time.flatMap({ StoredTaskFormat.hourMinute(from: $0) }) {
            initialDate = Calendar.current.date(
                bySettingHour: time.hour,
                minute: time.minute,
                second: 0,
                of: initialDate
            ) ?? initialDate
        }
        editDateTime = initialDate
        editBaseline = draft
        loadedEditID = editingTask.id
    }

    private func saveEdit(at index: Int, baseline: PendingCallEditDraft) {
        guard tasks.indices.contains(index) else { return }
        // 기기 언어 형식("오후 3:00")으로 저장하면 알림·정렬이 읽지 못하므로 저장 형식을 고정합니다.
        let edited = PendingCallEditDraft(
            scope: baseline.scope,
            name: editName,
            category: editCategory,
            date: editCategory == "Appointment"
                ? StoredTaskFormat.date.string(from: editDateTime)
                : nil,
            time: editHasNoTime ? nil : StoredTaskFormat.time.string(from: editDateTime)
        )
        // 바뀐 내용이 있을 때만 승인 대상을 다시 고정하도록 무효화합니다.
        if tasks[index].applyEdit(edited, from: baseline) {
            tasks[index].invalidatePreparedTargets()
        }
        Haptic.impact(.light)
        withAnimation(.spring()) { editingTask = nil }
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
        VStack(spacing: 0) {
            // 큰 글씨에서도 예시가 잘리지 않도록 본문만 스크롤하고 버튼은 아래에 고정한다.
            ScrollView {
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
                                    .fixedSize(horizontal: false, vertical: true)

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
                }
                .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)

            // 쓸어내리기 외에도 닫을 수 있게 명시적인 버튼을 둔다.
            Button { dismiss() } label: {
                Text(L.voice.guideStart)
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .foregroundStyle(DesignSystem.Colors.onPrimary)
                    .background(LinearGradient(
                        colors: [DesignSystem.Colors.primary, DesignSystem.Colors.primary.opacity(0.78)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ), in: Capsule())
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .background(DesignSystem.Colors.background)
    }
}

// MARK: - Preview
struct HomeVoiceInterfaceView_Previews: PreviewProvider {
    static var previews: some View {
        HomeVoiceInterfaceView(activeTab: .constant(.voice), isModalVisible: .constant(false))
            .environmentObject(CloudLLMManager())
            .environmentObject(TaskManager())
            .environmentObject(AuthManager())
            .environmentObject(NetworkMonitor.shared)
    }
}
