import SwiftUI
import SwiftData

@main
struct WaitWhatApp: App {
    // MARK: - SwiftData Container
    let container: ModelContainer = {
        let schema = Schema([AppTask.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("SwiftData ModelContainer 초기화 실패: \(error)")
        }
    }()

    // MARK: - App-level State
    @StateObject private var taskManager  = TaskManager()
    @StateObject private var cloudLLM     = CloudLLMManager()
    @StateObject private var networkMonitor = NetworkMonitor.shared

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(taskManager)
                .environmentObject(cloudLLM)
                .environmentObject(networkMonitor)
                .modelContainer(container)
                .onAppear {
                    // ModelContext 주입 (TaskManager → SwiftData)
                    taskManager.configure(context: container.mainContext)
                    // 알림 권한 요청 (최초 1회)
                    NotificationManager.shared.requestAuthorization()
                }
        }
    }
}
