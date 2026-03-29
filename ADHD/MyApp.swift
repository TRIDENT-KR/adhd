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
            } else {
                LoginView()
                    .environmentObject(authManager)
                    .preferredColorScheme(colorScheme)
            }
        }
    }
}
