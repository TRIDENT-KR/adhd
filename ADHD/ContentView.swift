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
        static let offlineAlertText = "Internet offline. Manual entries will save. Voice entry paused."
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

    var body: some View {
        ZStack {
            DesignSystem.Colors.background
                .ignoresSafeArea()

            VStack {
                // Top Bar
                HStack {
                    Spacer()
                    Button(action: {
                        Task {
                            await authManager.signOut()
                        }
                    }) {
                        Image(systemName: "rectangle.portrait.and.arrow.right") // 로그아웃 아이콘으로 변경
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
                            : (isBreathing ? 1.05 : 0.95)

                        Circle()
                            .fill(DesignSystem.Colors.primaryFixedDim.opacity(
                                voiceManager.isListening ? 0.6 : 0.3
                            ))
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
                    }

                    // ── 상태 텍스트 ──
                    Group {
                        if cloudLLM.isProcessing || voiceManager.isProcessing {
                            // 분석 진행 중
                            Text("Analyzing...")
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                        } else if !voiceManager.recognizedText.isEmpty {
                            // 인식된 텍스트 또는 결과 메시지 표시
                            Text(voiceManager.recognizedText)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                        } else if voiceManager.isListening {
                            Text("Listening...")
                                .foregroundColor(DesignSystem.Colors.primary)
                        } else {
                            // Placeholder — 모든 완료 Exit Path에서 recognizedText = ""로 초기화하면 복귀
                            Text("What should I remember for you?")
                                .foregroundColor(DesignSystem.Colors.primary)
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
                }

                Spacer()
                Spacer(minLength: 120) // 바텀 바 공간 확보
            }
        }
    }

    // MARK: - Mic Button Handler
    /// Trigger 2 (Task 3): 오프라인이면 배너를 3초간 표시하고 녹음을 차단합니다.
    private func handleMicTap() {
        if !networkMonitor.isConnected && !voiceManager.isListening {
            networkMonitor.showOfflineBannerTemporarily()
            return
        }
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
                    let parsedTask = try await cloudLLM.analyzeText(text: text)
                    print("🤖 Gemini 파싱 결과: \(parsedTask)")
                    taskManager.add(task: parsedTask)

                    // ✅ 성공 Exit Path: 2초간 성공 메시지 → Placeholder 복구
                    await MainActor.run {
                        voiceManager.recognizedText = "✅ Saved! Check Routine or Planner tab."
                        voiceManager.isProcessing   = false
                    }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await MainActor.run {
                        if voiceManager.recognizedText.starts(with: "✅") {
                            voiceManager.recognizedText = ""
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
            TabBarItem(iconName: "square.grid.2x2", label: "Routine", isActive: activeTab == .routine) {
                withAnimation(.spring()) { activeTab = .routine }
            }
            Spacer()
            TabBarItem(iconName: "mic.fill", label: "Voice", isActive: activeTab == .voice) {
                withAnimation(.spring()) { activeTab = .voice }
            }
            Spacer()
            TabBarItem(iconName: "calendar", label: "Planner", isActive: activeTab == .planner) {
                withAnimation(.spring()) { activeTab = .planner }
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
        .background(DesignSystem.Colors.surfaceContainerLow)
        .clipShape(Capsule())
        .padding(.bottom, 24)
        .padding(.horizontal, 24)
    }
}

struct TabBarItem: View {
    let iconName: String
    let label:    String
    let isActive: Bool
    let action:   () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 24, weight: isActive ? .semibold : .regular))
                Text(label)
                    .font(DesignSystem.Typography.labelSm)
                    .tracking(0.3)
            }
            .foregroundColor(
                isActive ? DesignSystem.Colors.primary : DesignSystem.Colors.onSurfaceVariant
            )
            .frame(width: 60)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Squishy Button Style
struct SquishyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.3), value: configuration.isPressed)
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

// MARK: - UIColor convenience for RGB bytes
extension UIColor {
    convenience init(r: UInt8, g: UInt8, b: UInt8) {
        self.init(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
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
