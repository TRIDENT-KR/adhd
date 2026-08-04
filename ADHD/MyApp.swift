import SwiftUI
import SwiftData
import UIKit
import AuthenticationServices

@main
struct MoraApp: App {
    static let presentationDemoMode: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-moraPresentationDemo")
        #else
        false
        #endif
    }()

    @StateObject private var accountStoreController = AccountStoreController()
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
    @State private var pendingStoreDeletionUserID: UUID?
    private let sessionCleanupCoordinator = AccountSessionCleanupCoordinator()

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
            rootContent
                .task(id: authManager.accessState) {
                    await synchronizeAccountStoreWithAuthState()
                }
                .task(id: networkMonitor.isConnected) {
                    await authManager.handleConnectivityChange(
                        isConnected: networkMonitor.isConnected
                    )
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: .moraAccountDeletionCompleted)
                ) { notification in
                    guard let userID = notification.object as? UUID else { return }
                    Task { @MainActor in
                        await removeCompletedAccountStore(for: userID)
                    }
                }
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        if let failureCode = accountStoreController.failureCode {
            PersistenceUnavailableView(
                code: failureCode,
                onRetry: retryPersistenceOperation
            )
                .preferredColorScheme(colorScheme)
                .environment(\.locale, Locale(identifier: appLanguage))
        } else if isPresentationDemoMode {
            if let container = accountStoreController.container {
                mainContent(container: container, scopeID: "presentation")
            } else {
                loadingView
            }
        } else {
            switch authManager.accessState {
            case .booting:
                loadingView

            case .deletionPending:
                AccountDeletionPendingView()
                    .environmentObject(authManager)
                    .preferredColorScheme(colorScheme)
                    .environment(\.locale, Locale(identifier: appLanguage))

            case .authenticatedOnline(let userID),
                 .authenticatedOfflineLimited(let userID):
                if accountStoreController.activeUserID == userID,
                   let container = accountStoreController.container {
                    accountContent(container: container, userID: userID)
                } else {
                    loadingView
                }

            case .signedOut, .lockedInvalidSession:
                LoginView()
                    .environmentObject(authManager)
                    .preferredColorScheme(colorScheme)
                    .environment(\.locale, Locale(identifier: appLanguage))
            }
        }
    }

    private var loadingView: some View {
        ProgressView()
            .tint(DesignSystem.Colors.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DesignSystem.Colors.background.ignoresSafeArea())
            .preferredColorScheme(colorScheme)
    }

    @ViewBuilder
    private func accountContent(container: ModelContainer, userID: UUID) -> some View {
        if !hasCompletedOnboarding {
            OnboardingView()
                .id(userID)
                .modelContainer(container)
                .preferredColorScheme(colorScheme)
                .environment(\.locale, Locale(identifier: appLanguage))
        } else {
            mainContent(container: container, scopeID: userID.uuidString)
        }
    }

    private func mainContent(container: ModelContainer, scopeID: String) -> some View {
        MainTabView()
            .id(scopeID)
            .environment(\.locale, Locale(identifier: appLanguage))
            .environmentObject(taskManager)
            .environmentObject(cloudLLM)
            .environmentObject(authManager)
            .environmentObject(networkMonitor)
            .environmentObject(subscriptionManager)
            .modelContainer(container)
            .preferredColorScheme(colorScheme)
            .task {
                taskManager.configure(context: container.mainContext)
                if isPresentationDemoMode && !hasSeededPresentationDemo {
                    seedPresentationDemoData(in: container)
                    hasSeededPresentationDemo = true
                }

                if !isPresentationDemoMode {
                    sessionCleanupCoordinator.restoreLocalExposure(taskManager: taskManager)
                }
                AlarmCoordinator.shared.onTaskConfirmed = { taskId in
                    taskManager.completeTask(id: taskId)
                }
            }
            .task {
                if !isPresentationDemoMode {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    NotificationManager.shared.requestAuthorization()
                }
            }
            .onOpenURL { url in
                handleWidgetDeepLink(url)
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    taskManager.checkAndResetDailyTasks()
                    taskManager.syncWidgetToggles()
                    taskManager.processPendingAlarmCompletions()
                    taskManager.rescheduleStrongTasksIfNeeded()
                    handlePendingDeepLink()
                    Task { @MainActor in
                        taskManager.writeWidgetSnapshot()
                        taskManager.cleanupOrphanedNotifications()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .alarmTaskCompleted)) { _ in
                taskManager.processPendingAlarmCompletions()
            }
            .onReceive(NotificationCenter.default.publisher(for: .premiumStatusChanged)) { _ in
                taskManager.rescheduleAllStrongTasks()
            }
            .onReceive(NotificationCenter.default.publisher(for: .alarmBackendChanged)) { _ in
                taskManager.rescheduleAllStrongTasks()
            }
    }

    @MainActor
    private func synchronizeAccountStoreWithAuthState() async {
        if isPresentationDemoMode {
            accountStoreController.activatePresentationStore()
            return
        }

        switch authManager.accessState {
        case .booting:
            return

        case .authenticatedOnline(let userID),
             .authenticatedOfflineLimited(let userID):
            if let activeUserID = accountStoreController.activeUserID,
               activeUserID != userID {
                await sessionCleanupCoordinator.lockLocalExposure(
                    taskManager: taskManager,
                    reason: .accountSwitch
                )
                accountStoreController.lock()
            }
            AccountPreferences.activate(for: userID)
            WidgetAccountScope.activate(AccountPreferences.scope(for: userID))
            subscriptionManager.activateLocalAccountScope(userID)
            accountStoreController.activate(for: userID)

        case .signedOut:
            await sessionCleanupCoordinator.lockLocalExposure(
                taskManager: taskManager,
                reason: .signedOut
            )
            accountStoreController.lock()

        case .lockedInvalidSession:
            await sessionCleanupCoordinator.lockLocalExposure(
                taskManager: taskManager,
                reason: .invalidSession
            )
            accountStoreController.lock()

        case .deletionPending:
            await sessionCleanupCoordinator.lockLocalExposure(
                taskManager: taskManager,
                reason: .deletionPending
            )
            accountStoreController.lock()
        }
    }

    @MainActor
    private func removeCompletedAccountStore(for userID: UUID) async {
        pendingStoreDeletionUserID = userID
        if accountStoreController.activeUserID == userID {
            await sessionCleanupCoordinator.lockLocalExposure(
                taskManager: taskManager,
                reason: .deletionCompleted
            )
            accountStoreController.lock()
            await Task.yield()
        }
        accountStoreController.deleteStoreAfterServerCompletion(for: userID)
        AccountPreferences.removeAll(for: userID)
        subscriptionManager.clearAccountCache(for: userID)
        if accountStoreController.failureCode == nil {
            pendingStoreDeletionUserID = nil
        }
    }

    @MainActor
    private func retryPersistenceOperation() {
        if let userID = pendingStoreDeletionUserID {
            accountStoreController.deleteStoreAfterServerCompletion(for: userID)
            if accountStoreController.failureCode == nil {
                pendingStoreDeletionUserID = nil
            }
            return
        }

        guard let userID = authManager.accessState.accountUserID else { return }
        AccountPreferences.activate(for: userID)
        WidgetAccountScope.activate(AccountPreferences.scope(for: userID))
        accountStoreController.activate(for: userID)
    }

    private func seedPresentationDemoData(in container: ModelContainer) {
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

private struct AccountDeletionPendingView: View {
    @EnvironmentObject private var authManager: AuthManager
    @State private var isWorking = false
    @State private var message: String?

    private var needsAppleReauthentication: Bool {
        authManager.accountDeletionNeedsAppleReauthentication
            || authManager.accountDeletionStatus == .requesting
    }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "person.crop.circle.badge.clock")
                .font(.system(size: 44, weight: .medium))
                .foregroundColor(DesignSystem.Colors.primary)

            VStack(spacing: 10) {
                Text(L.settings.deletionPendingTitle)
                    .font(DesignSystem.Typography.titleSm)
                Text(L.settings.deletionPendingMessage)
                    .font(DesignSystem.Typography.bodyMd)
                    .multilineTextAlignment(.center)
                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.75))

                if let requestID = authManager.accountDeletionRequestID {
                    Text("Request ID: \(requestID.uuidString.lowercased())")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            if needsAppleReauthentication {
                SignInWithAppleButton(.continue) { request in
                    authManager.prepareAppleAccountDeletionRequest(request)
                } onCompletion: { result in
                    Task { @MainActor in
                        isWorking = true
                        defer { isWorking = false }
                        do {
                            let code = try await authManager
                                .reauthenticateForAccountDeletion(result)
                            try await authManager.deleteAccount(
                                appleAuthorizationCode: code
                            )
                            message = nil
                        } catch let error as AccountDeletionClientError {
                            message = error.localizedDescription
                        } catch {
                            message = L.settings.deletionStatusPending
                        }
                    }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(width: 280, height: 50)
                .disabled(isWorking)
            } else {
                Button {
                    Task { @MainActor in
                        isWorking = true
                        defer { isWorking = false }
                        do {
                            try await authManager.refreshAccountDeletionStatus()
                            message = nil
                        } catch {
                            message = L.settings.deletionStatusPending
                        }
                    }
                } label: {
                    if isWorking { ProgressView() } else { Text(L.settings.checkDeletionStatus) }
                }
                .buttonStyle(.borderedProminent)
            }

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Link(
                L.settings.contactSupport,
                destination: URL(string: "mailto:trident1398@gmail.com")!
            )
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignSystem.Colors.background.ignoresSafeArea())
    }
}

private struct PersistenceUnavailableView: View {
    let code: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 44, weight: .medium))
                .foregroundColor(DesignSystem.Colors.primary)
                .accessibilityHidden(true)

            VStack(spacing: 12) {
                Text(L.persistence.title)
                    .font(DesignSystem.Typography.titleSm)
                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant)

                Text(L.persistence.message)
                    .font(DesignSystem.Typography.bodyMd)
                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.75))
                    .multilineTextAlignment(.center)

                Text(code)
                    .font(.caption.monospaced())
                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.6))
            }

            VStack(spacing: 12) {
                Button(action: onRetry) {
                    Text(L.voice.tryAgain)
                        .font(DesignSystem.Typography.bodyMd.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)

                Link(destination: URL(string: "mailto:trident1398@gmail.com?subject=Mora%20\(code)")!) {
                    Text(L.settings.contactSupport)
                        .font(DesignSystem.Typography.bodyMd)
                }
            }
            .frame(maxWidth: 320)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignSystem.Colors.background.ignoresSafeArea())
        .accessibilityElement(children: .combine)
    }
}
