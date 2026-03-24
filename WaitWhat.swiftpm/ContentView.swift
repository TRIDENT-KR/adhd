import SwiftUI

// MARK: - Design System Tokens
struct DesignSystem {
    struct Colors {
        // Core Palette
        static let background = Color(hex: "#F9F9F7") // warm paper
        static let primary = Color(hex: "#934A2E") // sophisticated terracotta
        static let primaryContainer = Color(hex: "#D27C5C")
        static let primaryFixedDim = Color(hex: "#FFB59B") // Used for voice pulse
        static let onSurfaceVariant = Color(hex: "#54433D") // Used for unselected icons/labels
        static let surfaceContainerLow = Color(hex: "#F4F4F2")
    }
    
    struct Gradients {
        static let primaryCTA = LinearGradient(
            colors: [Colors.primary, Colors.primaryContainer],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    
    struct Typography {
        // Fallback to system fonts with adjusted tracking to mimic Manrope/Inter rules
        static let displayLg = Font.system(size: 34, weight: .semibold, design: .default)
        static let titleSm = Font.system(size: 20, weight: .medium, design: .default)
        static let bodyMd = Font.system(size: 16, weight: .regular, design: .default)
        static let labelSm = Font.system(size: 12, weight: .medium, design: .default)
    }
}

// MARK: - Main View
struct HomeVoiceInterfaceView: View {
    @EnvironmentObject var llmManager: LLMManager
    @EnvironmentObject var taskManager: TaskManager
    @StateObject private var voiceManager = VoiceInputManager()
    @State private var isBreathing = false
    
    var body: some View {
        ZStack {
            // 1. Off-white background covering the whole screen
            DesignSystem.Colors.background
                .ignoresSafeArea()
            
            VStack {
                // Top Bar: Settings Icon (Top Right)
                HStack {
                    Spacer()
                    Button(action: {
                        // Settings Action
                    }) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 24, weight: .light))
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                
                Spacer()
                
                // Center Content: Voice Component
                VStack(spacing: 32) { // Wide margin to avoid crowding
                    
                    // Voice Pulse Component (Large Circular Microphone Button)
                    ZStack {
                        // Outer breathing pulse / Audio level ripple
                        let pulseScale = voiceManager.isListening ? 1.0 + (voiceManager.audioPower * 0.5) : (isBreathing ? 1.05 : 0.95)
                        
                        Circle()
                            .fill(DesignSystem.Colors.primaryFixedDim.opacity(voiceManager.isListening ? 0.6 : 0.3))
                            .frame(width: 180, height: 180)
                            .scaleEffect(pulseScale)
                            .animation(
                                voiceManager.isListening ? .easeOut(duration: 0.1) : .easeInOut(duration: 2.0).repeatForever(autoreverses: true),
                                value: pulseScale
                            )
                        
                        // Inner Button with Gradient and soft depth
                        Button(action: {
                            voiceManager.toggleListening()
                        }) {
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
                        .buttonStyle(SquishyButtonStyle()) // Custom tactile feedback
                    }
                    .onAppear {
                        isBreathing = true
                        voiceManager.onSpeechFinalized = { text in
                            guard !text.isEmpty else { return }
                            Task {
                                do {
                                    let jsonResponse = try await llmManager.generate(prompt: text)
                                    print("🤖 SLM 응답 결과:\n\(jsonResponse)")
                                    taskManager.ingest(jsonString: jsonResponse)
                                    
                                    // Reset UI states after inference and show temporary success message
                                    await MainActor.run {
                                        voiceManager.recognizedText = "✅ 저장 완료! Planner와 Routine 탭을 확인하세요."
                                        voiceManager.isProcessing = false
                                        
                                        // 3초 뒤에 원래 문구로 복귀
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                            if voiceManager.recognizedText.starts(with: "✅") {
                                                voiceManager.recognizedText = ""
                                            }
                                        }
                                    }
                                } catch {
                                    print("LLM Error: \(error)")
                                    await MainActor.run { voiceManager.isProcessing = false }
                                }
                            }
                        }
                    }
                    
                    // Prompt Text / Real-time Transcribed Text
                    Group {
                        if llmManager.isGenerating || voiceManager.isProcessing {
                            Text("분석 중...")
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                        } else if !voiceManager.recognizedText.isEmpty {
                            Text(voiceManager.recognizedText)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                        } else if voiceManager.isListening {
                            Text("듣는 중...")
                                .foregroundColor(DesignSystem.Colors.primary)
                        } else {
                            Text("What should I remember for you?")
                                .foregroundColor(DesignSystem.Colors.primary) // Anchor focus point
                        }
                    }
                    .font(DesignSystem.Typography.titleSm)
                    .tracking(-0.5) // -2% letter spacing rule for headlines
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .animation(.easeInOut, value: voiceManager.recognizedText)
                    .animation(.easeInOut, value: voiceManager.isListening)
                    .animation(.easeInOut, value: voiceManager.isProcessing)
                }
                
                Spacer()
                
                Spacer(minLength: 120) // Space for floating bottom bar in MainTabView
            }
        }
    }
}

enum TabSelection {
    case routine, voice, planner
}

// MARK: - Custom Bottom Bar
struct CustomBottomBar: View {
    @Binding var activeTab: TabSelection

    var body: some View {
        HStack(spacing: 0) {
            // Tab 1: Routine
            TabBarItem(iconName: "square.grid.2x2", label: "Routine", isActive: activeTab == .routine) {
                withAnimation(.spring()) {
                    activeTab = .routine
                }
            }
            
            Spacer()
            
            // Tab 2: Mic (Active)
            TabBarItem(iconName: "mic.fill", label: "Voice", isActive: activeTab == .voice) {
                withAnimation(.spring()) {
                    activeTab = .voice
                }
            }
            
            Spacer()
            
            // Tab 3: Planner
            TabBarItem(iconName: "calendar", label: "Planner", isActive: activeTab == .planner) {
                withAnimation(.spring()) {
                    activeTab = .planner
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
        .background(DesignSystem.Colors.surfaceContainerLow) // Tray level depth
        .clipShape(Capsule()) // 둥글고 부드러운 알약 형태로 깎기
        .padding(.bottom, 24) // 화면 하단에서 띄우기
        .padding(.horizontal, 24) // 좌우 여백을 주어 공중에 둥둥 뜬 플로팅 느낌 주기
    }
}

struct TabBarItem: View {
    let iconName: String
    let label: String
    let isActive: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 24, weight: isActive ? .semibold : .regular))
                Text(label)
                    .font(DesignSystem.Typography.labelSm)
                    .tracking(0.3) // +0.02em breathing room rule for labels
            }
            .foregroundColor(isActive ? DesignSystem.Colors.primary : DesignSystem.Colors.onSurfaceVariant)
            .frame(width: 60) // Fixed width for nice alignment
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Squishy Button Style (Interaction Rules)
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
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Preview
struct HomeVoiceInterfaceView_Previews: PreviewProvider {
    static var previews: some View {
        HomeVoiceInterfaceView()
    }
}
