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
                return try ModelContainer(for: schema, configurations: [config])
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

    var body: some Scene {
        WindowGroup {
            Group {
                if !authManager.isSessionLoaded {
                    // 세션 확인 중 — 가벼운 스플래시로 렉 없이 대기
                    DesignSystem.Colors.background
                        .ignoresSafeArea()
                } else if authManager.session != nil {
                    MainTabView()
                        .preferredColorScheme(colorScheme)
                        .environment(\.locale, Locale(identifier: appLanguage))
                        .environmentObject(taskManager)
                        .environmentObject(cloudLLM)
                        .environmentObject(authManager)
                        .environmentObject(networkMonitor)
                        .modelContainer(container)
                        .task {
                            // ModelContext 주입 (TaskManager → SwiftData)
                            taskManager.configure(context: container.mainContext)
                            // 알림 권한 요청 (최초 1회) — UI 렌더링 후 비동기 실행
                            NotificationManager.shared.requestAuthorization()
                        }
                        .onChange(of: scenePhase) { oldPhase, newPhase in
                            if newPhase == .active {
                                // 앱이 활성화될 때마다 날짜 체크 및 리셋 실행
                                taskManager.checkAndResetDailyTasks()
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
