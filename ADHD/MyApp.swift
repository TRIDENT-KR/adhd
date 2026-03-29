import SwiftUI
import SwiftData

@main
struct WaitWhatApp: App {
    // MARK: - SwiftData Container
    /// 스키마 변경 시 기존 데이터와 호환되지 않으면 저장소를 초기화하여 크래시를 방지합니다.
    let container: ModelContainer = {
        let schema = Schema([AppTask.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            print("⚠️ SwiftData 초기화 실패, 저장소 재생성: \(error)")
            // 기존 저장소 삭제 후 재생성 (스키마 마이그레이션 실패 복구)
            let url = config.url
            if FileManager.default.fileExists(atPath: url.path()) {
                try? FileManager.default.removeItem(at: url)
                // WAL, SHM 파일도 정리
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

    @StateObject private var taskManager = TaskManager()
    @StateObject private var cloudLLM = CloudLLMManager()
    @StateObject private var authManager = AuthManager()
    @StateObject private var networkMonitor = NetworkMonitor.shared
    @AppStorage("appTheme") private var appTheme: String = "system"
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
            if authManager.session != nil {
                MainTabView()
                    .preferredColorScheme(colorScheme)
                    .environment(\.locale, Locale(identifier: appLanguage))
                    .id(appLanguage)
                    .environmentObject(taskManager)
                    .environmentObject(cloudLLM)
                    .environmentObject(authManager)
                    .environmentObject(networkMonitor)
                    .modelContainer(container)
                    .onAppear {
                        // ModelContext 주입 (TaskManager → SwiftData)
                        taskManager.configure(context: container.mainContext)
                        // 알림 권한 요청 (최초 1회)
                        NotificationManager.shared.requestAuthorization()
                    }
                    .id(appLanguage) // 언어 변경 시 전체 뷰 재렌더링 강제
                    .environment(\.locale, Locale(identifier: appLanguage))
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
                    .id(appLanguage)
            }
        }
    }
}
