import SwiftUI
import SwiftData

@main
struct WaitWhatApp: App {
    // MARK: - SwiftData Container
    /// 스키마 변경 시 기존 데이터와 호환되지 않으면 저장소를 초기화하여 크래시를 방지합니다.
    private static let sharedContainer: ModelContainer = {
        let schema = Schema([AppTask.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            print("⚠️ SwiftData 초기화 실패, 저장소 재생성: \(error)")
            let url = config.url
            if FileManager.default.fileExists(atPath: url.path()) {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: URL(filePath: url.path() + "-wal"))
                try? FileManager.default.removeItem(at: URL(filePath: url.path() + "-shm"))
            }
            do {
                // 실패한 config 재사용 불가 — 새 인스턴스 생성
                let freshConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
                return try ModelContainer(for: schema, configurations: [freshConfig])
            } catch {
                fatalError("SwiftData 복구 불가: \(error)")
            }
        }
    }()
    
    private var container: ModelContainer { Self.sharedContainer }

    @StateObject private var taskManager = TaskManager()
    @StateObject private var cloudLLM = CloudLLMManager()
    @StateObject private var authManager = AuthManager()
    @StateObject private var networkMonitor = NetworkMonitor.shared
    @AppStorage("appTheme") private var appTheme: String = "system"
    /// 언어 변경을 감지하여 environment(locale) 전파. .id()는 사용하지 않아 NavigationStack을 보존
    @AppStorage("appLanguage") private var appLanguage: String = "en"
    @Environment(\.scenePhase) private var scenePhase

    private var colorScheme: ColorScheme? {
        switch appTheme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    // MARK: - Widget Deep Link Handling
    private func handleWidgetDeepLink(_ url: URL) {
        guard url.scheme == "waitwhat", url.host == "tab" else { return }
        let tabName = url.lastPathComponent
        let tab: TabSelection
        switch tabName {
        case "routine": tab = .routine
        case "planner": tab = .planner
        default:        tab = .voice
        }
        NotificationCenter.default.post(name: .widgetDeepLink, object: tab)
    }

    private func handlePendingDeepLink() {
        guard let defaults = UserDefaults(suiteName: "group.trident-KR.ADHD"),
              let link = defaults.string(forKey: "widgetDeepLink") else { return }
        defaults.removeObject(forKey: "widgetDeepLink")
        let tab: TabSelection
        switch link {
        case "routine": tab = .routine
        case "planner": tab = .planner
        default:        tab = .voice
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(name: .widgetDeepLink, object: tab)
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if !authManager.isSessionLoaded {
                    // 세션 확인 중 — 스플래시 화면 표시
                    SplashView()
                        .preferredColorScheme(colorScheme)
                } else if authManager.session != nil {
                    ZStack {
                        MainTabView()
                            .environment(\.locale, Locale(identifier: appLanguage))
                            .environmentObject(taskManager)
                            .environmentObject(cloudLLM)
                            .environmentObject(authManager)
                            .environmentObject(networkMonitor)
                            .modelContainer(container)

                        // 데이터 로딩 완료 전 스플래시 오버레이
                        if !taskManager.isReady {
                            SplashView()
                                .transition(.opacity)
                                .zIndex(1)
                        }
                    }
                    .animation(.easeOut(duration: 0.4), value: taskManager.isReady)
                    .preferredColorScheme(colorScheme)
                    .task {
                        // ModelContext 주입 (TaskManager → SwiftData)
                        taskManager.configure(context: container.mainContext)

                        // 알람 확인 시 자동 완료 연동
                        AlarmManager.shared.onTaskConfirmed = { taskId in
                            taskManager.completeTask(id: taskId)
                        }
                    }
                    .task {
                        // 알림 권한 요청 — 초기 렌더링 완료 후 지연 실행
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        NotificationManager.shared.requestAuthorization()
                    }
                        .onOpenURL { url in
                            handleWidgetDeepLink(url)
                        }
                        .onChange(of: scenePhase) { oldPhase, newPhase in
                            if newPhase == .active {
                                // 앱이 활성화될 때마다 날짜 체크 및 리셋 실행
                                taskManager.checkAndResetDailyTasks()
                                // 위젯에서 토글한 태스크 동기화
                                taskManager.syncWidgetToggles()
                                // 위젯 데이터 최신 상태로 갱신
                                taskManager.writeWidgetSnapshot()
                                // 위젯 딥링크 처리 (AppIntent 경유)
                                handlePendingDeepLink()
                            }
                        }
                } else {
                    LoginView()
                        .environmentObject(authManager)
                        .preferredColorScheme(colorScheme)
                        .environment(\.locale, Locale(identifier: appLanguage))
                }
            }
        }
    }
}

// MARK: - Splash Screen
private struct SplashView: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            DesignSystem.Colors.background
                .ignoresSafeArea()
            VStack(spacing: 16) {
                Text("Wait, What?")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundColor(DesignSystem.Colors.primary)
                ProgressView()
                    .tint(DesignSystem.Colors.primary)
            }
            .scaleEffect(pulse ? 1.02 : 0.98)
            .opacity(pulse ? 1.0 : 0.7)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
        }
    }
}
