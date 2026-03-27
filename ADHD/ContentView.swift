import SwiftUI

// MARK: - Design System Tokens
struct DesignSystem {
    struct Colors {
        // Adaptive colors: light/dark mode 자동 전환 (main 브랜치 다크모드 지원 수용)
        static let background = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(r: 0x1A, g: 0x1A, b: 0x1A)
                : UIColor(r: 0xF9, g: 0xF9, b: 0xF7)
        })

        static let primary = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(r: 0xFF, g: 0xB5, b: 0x9B)
                : UIColor(r: 0x93, g: 0x4A, b: 0x2E)
        })

        static let primaryContainer = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(r: 0x7C, g: 0x3F, b: 0x24)
                : UIColor(r: 0xD2, g: 0x7C, b: 0x5C)
        })

        static let primaryFixedDim = Color(hex: "#FFB59B")

        static let onSurfaceVariant = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(r: 0xCF, g: 0xC0, b: 0xB8)
                : UIColor(r: 0x54, g: 0x43, b: 0x3D)
        })

        static let surfaceContainerLow = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(r: 0x25, g: 0x25, b: 0x25)
                : UIColor(r: 0xF4, g: 0xF4, b: 0xF2)
        })

        static let tertiary = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(r: 0x4F, g: 0xDB, b: 0xD1)
                : UIColor(r: 0x00, g: 0x6A, b: 0x63)
        })
    }

    struct Gradients {
        static let primaryCTA = LinearGradient(
            colors: [Colors.primary, Colors.primaryContainer],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    struct Typography {
        static let displayLg = Font.system(size: 34, weight: .semibold, design: .default)
        static let titleSm   = Font.system(size: 20, weight: .medium,   design: .default)
        static let bodyMd    = Font.system(size: 16, weight: .regular,  design: .default)
        static let labelSm   = Font.system(size: 12, weight: .medium,   design: .default)
    }

    // MARK: - Strings
    struct Strings {
        /// 오프라인 배너에 표시되는 영어 문구 (Task 2)
        static var offlineAlertText: String { L.offlineText }
    }
}

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

    var body: some View {
        ZStack {
            DesignSystem.Colors.background
                .ignoresSafeArea()

            VStack {
                // Top Bar
                HStack {
                    Spacer()
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)

                Spacer()

                VStack(spacing: 32) {

                    // ── Voice Pulse + Mic Button ──
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

                        Button(action: { handleMicTap() }) {
                            ZStack {
                                Circle()
                                    .fill(DesignSystem.Gradients.primaryCTA)
                                    .frame(width: 120, height: 120)

                                Image(systemName: voiceManager.isListening ? "stop.fill" : "mic.fill")
                                    .font(.system(size: 40, weight: .medium))
                                    .foregroundColor(.white)
                                    .contentTransition(.symbolEffect(.replace))
                            }
                        }
                        .buttonStyle(SquishyButtonStyle())
                        // 분석 중에는 버튼 비활성화
                        .disabled(cloudLLM.isProcessing || voiceManager.isProcessing)
                    }
                    .onAppear {
                        isBreathing = true
                        // setupSpeechCallback()은 process(intents:) 배치 처리 + 오프라인 방어 + Placeholder 복귀를 모두 포함합니다.
                        setupSpeechCallback()
                        // 1.5초 후 플레이스홀더 페이드 아웃 → 마이크 버튼만 남김 (Zero Clutter)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation(.easeOut(duration: 0.8)) {
                                showPlaceholder = false
                            }
                        }
                    }

                    // ── 상태 텍스트 / 성공 체크 ──
                    Group {
                        if showSuccessCheck {
                            // 성공: 체크마크 애니메이션 (텍스트 없이 시각+햅틱 피드백만)
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 48))
                                .foregroundColor(DesignSystem.Colors.tertiary)
                                .transition(.scale.combined(with: .opacity))
                        } else if cloudLLM.isProcessing || voiceManager.isProcessing {
                            Text(L.voiceAnalyzing)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                        } else if !voiceManager.recognizedText.isEmpty {
                            Text(voiceManager.recognizedText)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                        } else if voiceManager.isListening {
                            Text(L.voiceListening)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                        } else {
                            // Placeholder — 1.5초 후 페이드 아웃하여 Zero Clutter 극대화
                            Text(L.voicePlaceholder)
                                .foregroundColor(DesignSystem.Colors.primary)
                                .opacity(showPlaceholder ? 1.0 : 0.0)
                        }
                    }
                    .font(DesignSystem.Typography.titleSm)
                    .tracking(-0.5)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .animation(.easeInOut, value: voiceManager.recognizedText)
                    .animation(.easeInOut, value: voiceManager.isListening)
                    .animation(.easeInOut, value: voiceManager.isProcessing)
                    .animation(.easeInOut, value: cloudLLM.isProcessing)
                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: showSuccessCheck)
                }

                Spacer()
                Spacer(minLength: 120) // 바텀 바 공간 확보
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(authManager)
                .environmentObject(taskManager)
        }
    }

    // MARK: - Mic Button Handler
    /// Trigger 2 (Task 3): 오프라인이면 배너를 3초간 표시하고 녹음을 차단합니다.
    private func handleMicTap() {
        if !networkMonitor.isConnected && !voiceManager.isListening {
            networkMonitor.showOfflineBannerTemporarily()
            return
        }
        // 인터랙션 시 플레이스홀더 복귀 (다음 idle 때 다시 페이드 아웃)
        showPlaceholder = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        voiceManager.toggleListening()
    }

    // MARK: - Speech Finalization Callback
    /// 성공/에러 모든 Exit Path에서 recognizedText를 ""로 초기화하여 Placeholder로 복귀합니다.
    private func setupSpeechCallback() {
        voiceManager.onSpeechFinalized = { [weak voiceManager] text in
            guard let voiceManager, !text.isEmpty else {
                // 빈 텍스트 → Placeholder 즉시 복구
                Task { @MainActor in
                    voiceManager?.recognizedText = ""
                    voiceManager?.isProcessing   = false
                }
                return
            }

            Task {
                do {
                    let parsedTasks = try await cloudLLM.analyzeText(text: text)
                    print("🤖 Gemini 파싱 결과: \(parsedTasks)")
                    taskManager.process(intents: parsedTasks)

                    // ✅ 성공 Exit Path: 체크마크 애니메이션 + 햅틱 → Placeholder 복구
                    await MainActor.run {
                        voiceManager.recognizedText = ""
                        voiceManager.isProcessing   = false
                        showSuccessCheck = true
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await MainActor.run {
                        showSuccessCheck = false
                        // 복귀 후 1.5초 뒤 다시 페이드 아웃
                        showPlaceholder = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation(.easeOut(duration: 0.8)) {
                                showPlaceholder = false
                            }
                        }
                    }
                } catch {
                    print("❌ Cloud API Error: \(error.localizedDescription)")
                    // ❌ 에러 Exit Path: 즉시 Placeholder 복구
                    await MainActor.run {
                        voiceManager.recognizedText = ""
                        voiceManager.isProcessing   = false
                    }
                }
            }
        }
    }
}

// MARK: - Tab Selection
enum TabSelection {
    case routine, voice, planner
}

// MARK: - Custom Bottom Bar
struct CustomBottomBar: View {
    @Binding var activeTab: TabSelection

    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            TabBarItem(iconName: "square.grid.2x2", label: L.tabRoutine, isActive: activeTab == .routine) {
                withAnimation(.spring()) { activeTab = .routine }
            }
            Spacer()
            TabBarItem(iconName: "mic.fill", label: L.tabVoice, isActive: activeTab == .voice) {
                withAnimation(.spring()) { activeTab = .voice }
            }
            Spacer()
            TabBarItem(iconName: "calendar", label: L.tabPlanner, isActive: activeTab == .planner) {
                withAnimation(.spring()) { activeTab = .planner }
            }
            Spacer()
        }
        .padding(.vertical, 12)
        .background(DesignSystem.Colors.background)
        .contentShape(Rectangle())
        .padding(.bottom, 20)
        .padding(.horizontal, 16)
    }
}

struct TabBarItem: View {
    let iconName: String
    let label:    String
    let isActive: Bool
    let action:   () -> Void

    var body: some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        }) {
            VStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: 26, weight: isActive ? .bold : .medium))
                    .scaleEffect(isActive ? 1.15 : 1.0)

                Text(label)
                    .font(DesignSystem.Typography.labelSm)
                    .fontWeight(isActive ? .semibold : .regular)
                    .opacity(isActive ? 1 : 0.6)

                // Active Dot Indicator
                Circle()
                    .fill(DesignSystem.Colors.primary)
                    .frame(width: 4, height: 4)
                    .opacity(isActive ? 1 : 0)
                    .offset(y: 2)
            }
            .foregroundColor(
                isActive ? DesignSystem.Colors.primary : DesignSystem.Colors.onSurfaceVariant.opacity(0.3)
            )
            .frame(width: 80, height: 56)
            .contentShape(Rectangle())
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isActive)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Squishy Button Style
struct SquishyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .animation(.easeOut(duration: 0.2), value: configuration.isPressed)
    }
}

// MARK: - Color Extension for Hex
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red:     Double(r) / 255,
            green:   Double(g) / 255,
            blue:    Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Locale Short Label
extension String {
    /// "en-US" → "EN", "ko-KR" → "KO", "ja-JP" → "JA"
    var localeShortLabel: String {
        String(self.prefix(2)).uppercased()
    }
}

// MARK: - UIColor convenience for RGB bytes
extension UIColor {
    convenience init(r: UInt8, g: UInt8, b: UInt8) {
        self.init(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var taskManager: TaskManager
    @Environment(\.dismiss) private var dismiss
    @State private var showLogoutConfirm = false
    @State private var showDeleteConfirm = false
    @State private var showClearCompletedConfirm = false
    @State private var showClearAllConfirm = false
    @AppStorage("appLanguage") private var appLanguage: String = "en"

    // Notifications
    @State private var routineReminders: Bool = !UserDefaults.standard.bool(forKey: "routineRemindersDisabled")
    @State private var appointmentReminders: Bool = !UserDefaults.standard.bool(forKey: "appointmentRemindersDisabled")
    @State private var remindBefore: Int = UserDefaults.standard.integer(forKey: NotificationManager.remindBeforeKey)
    @State private var notificationSound: Bool = !UserDefaults.standard.bool(forKey: "notificationSoundDisabled")

    // Appearance
    @AppStorage("appTheme") private var appTheme: String = "system"
    @AppStorage("hapticEnabled") private var hapticEnabled: Bool = true

    private let supportedLocales: [(id: String, label: String)] = [
        ("en-US", "English (US)"),
        ("en-GB", "English (UK)"),
        ("ko-KR", "한국어"),
        ("ja-JP", "日本語"),
    ]

    private var remindBeforeOptions: [(value: Int, label: String)] {[
        (0, L.settings.atTime),
        (5, "5 \(L.settings.minBefore)"),
        (10, "10 \(L.settings.minBefore)"),
        (15, "15 \(L.settings.minBefore)"),
        (30, "30 \(L.settings.minBefore)"),
    ]}

    var body: some View {
        NavigationView {
            List {
                // ── Account ──
                Section {
                    // 프로필 정보
                    HStack {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(DesignSystem.Colors.primary.opacity(0.6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(authManager.userEmail ?? "User")
                                .font(DesignSystem.Typography.bodyMd)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                            Text("Apple ID")
                                .font(DesignSystem.Typography.labelSm)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                        }
                    }
                    .padding(.vertical, 4)

                    Button(action: { showLogoutConfirm = true }) {
                        HStack {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                            Text(L.settings.logOut)
                        }
                        .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                    }

                    Button(action: { showDeleteConfirm = true }) {
                        HStack {
                            Image(systemName: "trash")
                            Text(L.settings.deleteAccount)
                        }
                        .foregroundColor(.red.opacity(0.7))
                    }
                } header: {
                    Text(L.settings.account)
                }

                // ── Language ──
                Section {
                    Picker(selection: $appLanguage) {
                        ForEach(supportedLocales, id: \.id) { locale in
                            Text(locale.label).tag(String(locale.id.prefix(2)).lowercased())
                        }
                    } label: {
                        HStack {
                            Image(systemName: "globe")
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                            Text(L.settings.language)
                        }
                    }
                    .onChange(of: appLanguage) { _, newValue in
                        // 음성 인식 locale도 함께 변경
                        let voiceLocale = supportedLocales.first { String($0.id.prefix(2)).lowercased() == newValue }?.id ?? "en-US"
                        UserDefaults.standard.set(voiceLocale, forKey: VoiceInputManager.speechLocaleKey)
                    }
                } header: {
                    Text(L.settings.language)
                }

                // ── Notifications ──
                Section {
                    Toggle(isOn: $routineReminders) {
                        HStack {
                            Image(systemName: "bell")
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                            Text(L.settings.routineReminders)
                        }
                    }
                    .onChange(of: routineReminders) { _, val in
                        UserDefaults.standard.set(!val, forKey: "routineRemindersDisabled")
                    }

                    Toggle(isOn: $appointmentReminders) {
                        HStack {
                            Image(systemName: "bell.badge")
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                            Text(L.settings.appointmentReminders)
                        }
                    }
                    .onChange(of: appointmentReminders) { _, val in
                        UserDefaults.standard.set(!val, forKey: "appointmentRemindersDisabled")
                    }

                    Picker(selection: $remindBefore) {
                        ForEach(remindBeforeOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "clock")
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                            Text(L.settings.remindBefore)
                        }
                    }
                    .onChange(of: remindBefore) { _, val in
                        UserDefaults.standard.set(val, forKey: NotificationManager.remindBeforeKey)
                    }

                    Toggle(isOn: $notificationSound) {
                        HStack {
                            Image(systemName: "speaker.wave.2")
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                            Text(L.settings.sound)
                        }
                    }
                    .onChange(of: notificationSound) { _, val in
                        UserDefaults.standard.set(!val, forKey: "notificationSoundDisabled")
                    }
                } header: {
                    Text(L.settings.notifications)
                }

                // ── Appearance ──
                Section {
                    Picker(selection: $appTheme) {
                        Text(L.settings.system).tag("system")
                        Text(L.settings.light).tag("light")
                        Text(L.settings.dark).tag("dark")
                    } label: {
                        HStack {
                            Image(systemName: "paintbrush")
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                            Text(L.settings.theme)
                        }
                    }

                    Toggle(isOn: $hapticEnabled) {
                        HStack {
                            Image(systemName: "hand.tap")
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                            Text(L.settings.haptic)
                        }
                    }
                } header: {
                    Text(L.settings.appearance)
                }

                // ── Data Management ──
                Section {
                    Button(action: { showClearCompletedConfirm = true }) {
                        HStack {
                            Image(systemName: "checkmark.circle")
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                            Text(L.settings.clearCompleted)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                        }
                    }

                    Button(action: { showClearAllConfirm = true }) {
                        HStack {
                            Image(systemName: "trash.circle")
                            Text(L.settings.clearAll)
                        }
                        .foregroundColor(.red.opacity(0.7))
                    }
                } header: {
                    Text(L.settings.dataManagement)
                }

                // ── About ──
                Section {
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                        Text(L.settings.version)
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                    }

                    Link(destination: URL(string: "https://waitwhat.app/privacy")!) {
                        HStack {
                            Image(systemName: "hand.raised")
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                            Text(L.settings.privacyPolicy)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12))
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.3))
                        }
                    }

                    Link(destination: URL(string: "https://waitwhat.app/terms")!) {
                        HStack {
                            Image(systemName: "doc.text")
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                            Text(L.settings.termsOfService)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12))
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.3))
                        }
                    }

                    Link(destination: URL(string: "mailto:support@waitwhat.app")!) {
                        HStack {
                            Image(systemName: "envelope")
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                            Text(L.settings.contactSupport)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12))
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.3))
                        }
                    }
                } header: {
                    Text(L.settings.about)
                }
            }
            .navigationTitle(L.settings.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L.settings.done) { dismiss() }
                        .foregroundColor(DesignSystem.Colors.primary)
                }
            }
            // Log Out 확인
            .alert(L.settings.logOut, isPresented: $showLogoutConfirm) {
                Button(L.settings.cancel, role: .cancel) {}
                Button(L.settings.logOut, role: .destructive) {
                    Task {
                        await authManager.signOut()
                        dismiss()
                    }
                }
            } message: {
                Text(L.settings.logOutConfirm)
            }
            // Delete Account 확인
            .alert(L.settings.deleteAccount, isPresented: $showDeleteConfirm) {
                Button(L.settings.cancel, role: .cancel) {}
                Button(L.settings.delete, role: .destructive) {
                    Task {
                        try? await authManager.deleteAccount()
                        dismiss()
                    }
                }
            } message: {
                Text(L.settings.deleteConfirm)
            }
            // Clear Completed 확인
            .alert(L.settings.clearCompleted, isPresented: $showClearCompletedConfirm) {
                Button(L.settings.cancel, role: .cancel) {}
                Button(L.settings.delete, role: .destructive) {
                    taskManager.deleteCompleted()
                }
            } message: {
                Text(L.settings.clearCompletedConfirm)
            }
            // Clear All Data 확인
            .alert(L.settings.clearAll, isPresented: $showClearAllConfirm) {
                Button(L.settings.cancel, role: .cancel) {}
                Button(L.settings.delete, role: .destructive) {
                    taskManager.deleteAll()
                }
            } message: {
                Text(L.settings.clearAllConfirm)
            }
        }
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
