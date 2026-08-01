import SwiftUI
import SwiftData
import UIKit

@main
struct MoraApp: App {
    static let presentationDemoMode: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-moraPresentationDemo")
        #else
        false
        #endif
    }()

    // MARK: - SwiftData Container
    /// 스키마 변경 시 기존 데이터와 호환되지 않으면 저장소를 초기화하여 크래시를 방지합니다.
    private static let sharedContainer: ModelContainer = {
        let schema = Schema([AppTask.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: presentationDemoMode)
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
                let freshConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: presentationDemoMode)
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
    @StateObject private var subscriptionManager = SubscriptionManager()
    @AppStorage("appTheme") private var appTheme: String = "system"
    /// 언어 변경을 감지하여 environment(locale) 전파. .id()는 사용하지 않아 NavigationStack을 보존
    @AppStorage("appLanguage") private var appLanguage: String = "en"
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasSeededPresentationDemo = false

    private var isPresentationDemoMode: Bool {
        Self.presentationDemoMode
    }

    private var colorScheme: ColorScheme? {
        switch appTheme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    // MARK: - Widget Deep Link Handling
    private func handleWidgetDeepLink(_ url: URL) {
        guard url.scheme == "mora" else { return }
        switch url.host {
        case "tab":
            let tabName = url.lastPathComponent
            let tab: TabSelection
            switch tabName {
            case "routine": tab = .routine
            case "planner": tab = .planner
            default:        tab = .voice
            }
            NotificationCenter.default.post(name: .widgetDeepLink, object: tab)
        case "paywall":
            // D13: 무료 사용자가 잠금 위젯 탭 → 앱 내 페이월 시트
            NotificationCenter.default.post(name: .openPaywall, object: nil)
        default:
            break
        }
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
                    // 세션 확인 중
                    ProgressView()
                        .tint(DesignSystem.Colors.primary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(DesignSystem.Colors.background.ignoresSafeArea())
                        .preferredColorScheme(colorScheme)
                } else if authManager.session != nil && !hasCompletedOnboarding {
                    // F1/D18: 로그인 직후 경량 온보딩 (기존 사용자는 뷰 내부에서 자동 통과 — D22)
                    OnboardingView()
                        .modelContainer(container)
                        .preferredColorScheme(colorScheme)
                        .environment(\.locale, Locale(identifier: appLanguage))
                } else if authManager.session != nil || isPresentationDemoMode {
                    MainTabView()
                        .environment(\.locale, Locale(identifier: appLanguage))
                        .environmentObject(taskManager)
                        .environmentObject(cloudLLM)
                        .environmentObject(authManager)
                        .environmentObject(networkMonitor)
                        .environmentObject(subscriptionManager)
                        .modelContainer(container)
                        .preferredColorScheme(colorScheme)
                    .task {
                        // ModelContext 주입 (TaskManager → SwiftData)
                        taskManager.configure(context: container.mainContext)
                        if isPresentationDemoMode && !hasSeededPresentationDemo {
                            seedPresentationDemoData()
                            hasSeededPresentationDemo = true
                        }

                        // 알람 확인 시 자동 완료 연동
                        AlarmCoordinator.shared.onTaskConfirmed = { taskId in
                            taskManager.completeTask(id: taskId)
                        }
                    }
                    .task {
                        // 알림 권한 요청 — 초기 렌더링 완료 후 지연 실행
                        if !isPresentationDemoMode {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            NotificationManager.shared.requestAuthorization()
                        }
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
                                // 알림 액션/AlarmKit Stop이 큐에 남긴 완료 요청 처리
                                taskManager.processPendingAlarmCompletions()
                                // biweekly/monthly/yearly 고정 알람 재무장 (Pro + AlarmKit 허용 시)
                                taskManager.rescheduleStrongTasksIfNeeded()
                                // 위젯 딥링크 처리 (AppIntent 경유)
                                handlePendingDeepLink()
                                // 위젯 스냅샷은 화면 렌더링 후 비동기 갱신 (DB fetch + WidgetCenter reload를 핫패스에서 제외)
                                Task { @MainActor in
                                    taskManager.writeWidgetSnapshot()
                                    // 삭제된 태스크의 고아 알림/알람 회수 (등록-삭제 경합·과거 잔재 자가치유)
                                    taskManager.cleanupOrphanedNotifications()
                                }
                            }
                        }
                        .onReceive(NotificationCenter.default.publisher(for: .alarmTaskCompleted)) { _ in
                            taskManager.processPendingAlarmCompletions()
                        }
                        .onReceive(NotificationCenter.default.publisher(for: .premiumStatusChanged)) { _ in
                            // 구독 상태 변경 → strong 태스크 백엔드 재라우팅 (AlarmKit ↔ UN)
                            taskManager.rescheduleAllStrongTasks()
                        }
                        .onReceive(NotificationCenter.default.publisher(for: .alarmBackendChanged)) { _ in
                            // AlarmKit 권한 최초 획득 → 기존 strong 태스크를 시스템 알람으로 이관
                            taskManager.rescheduleAllStrongTasks()
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

    private func seedPresentationDemoData() {
        let context = container.mainContext
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)
        let tasks = [
            AppTask(task: "Morning medication", time: "09:00 AM", category: "Routine", urgency: .strong),
            AppTask(task: "20-minute walk", time: "12:30 PM", category: "Routine", urgency: .weak),
            AppTask(task: "Wind down", time: "10:30 PM", category: "Routine", urgency: .weak),
            AppTask(task: "Design review", time: "02:00 PM", date: today, category: "Appointment", urgency: .strong),
            AppTask(task: "Dentist appointment", time: "03:30 PM", date: tomorrow, category: "Appointment", urgency: .strong),
        ]
        tasks.forEach(context.insert)
        try? context.save()
    }
}
