import SwiftUI
import SwiftData
import Combine
import UIKit
import AuthenticationServices

/// 알림 delegate는 앱 실행이 끝나기 전에 연결해야 합니다.
/// 잠금화면 알림 액션으로 백그라운드에서 깨어나면 SwiftUI 화면이 만들어지지 않기 때문입니다.
final class MoraAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        NotificationManager.shared.configureNotificationHandling()
        return true
    }
}

@main
struct MoraApp: App {
    @UIApplicationDelegateAdaptor(MoraAppDelegate.self) private var appDelegate
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
    @StateObject private var adultEligibility = AdultEligibilityManager.shared
    @AppStorage("appTheme") private var appTheme: String = "system"
    /// 언어 변경을 감지하여 environment(locale) 전파. .id()는 사용하지 않아 NavigationStack을 보존
    @AppStorage("appLanguage") private var appLanguage: String = AppLanguage.preferred().rawValue
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasSeededPresentationDemo = false
    @State private var exposedScopeID: UUID?
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
    /// 앱 루트에서 받습니다. 앱이 꺼져 있다가 위젯으로 열리면 아직 로딩 화면이라 메인 화면이 없으므로,
    /// 고른 탭을 WidgetDeepLinkInbox에 맡겨 두고 메인 화면이 뜰 때 엽니다. 이미 떠 있으면 알림으로 바로 옮깁니다.
    private func handleWidgetDeepLink(_ url: URL) {
        guard url.scheme == "mora" else { return }
        switch url.host {
        case "tab":
            guard let tab = WidgetDeepLink.tab(from: url) else { return }
            // 위젯은 오늘 할 일만 보여 주므로, 플래너가 다른 날을 보고 있었어도 오늘로 엽니다.
            if tab == .planner {
                NotificationCenter.default.post(name: .plannerJumpToDate, object: Date())
            }
            WidgetDeepLinkInbox.store(tab)
            NotificationCenter.default.post(name: .widgetDeepLink, object: nil)
        case "paywall":
            // D13: 무료 사용자가 잠금 위젯 탭 → 앱 내 페이월 시트
            NotificationCenter.default.post(name: .openPaywall, object: nil)
        default:
            break
        }
    }

    var body: some Scene {
        WindowGroup {
            rootContent
                .alert(L.authRelease.deletionCompleteTitle, isPresented: Binding(
                    get: { authManager.showsDeletionCompletion && authManager.pendingLocalDeletionUserID == nil },
                    set: { if !$0 { authManager.dismissDeletionCompletion() } }
                )) {
                    Button(L.settings.done) { authManager.dismissDeletionCompletion() }
                } message: {
                    Text(L.authRelease.deletionCompleteMessage)
                }
                .task(id: AdultGateContext(auth: authManager.accessState, revision: adultEligibility.revision)) {
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
                // 위젯 링크는 로딩·온보딩 화면에서도 받을 수 있게 루트에 둡니다 (콜드 런치 포함).
                .onOpenURL { url in
                    handleWidgetDeepLink(url)
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
                if !adultEligibility.allowsLocalUse(for: userID) {
                    adultEligibilityContent(scopeID: userID)
                } else if exposedScopeID == userID, accountStoreController.activeUserID == userID,
                   let container = accountStoreController.container {
                    accountContent(container: container, userID: userID)
                } else {
                    loadingView
                }

            // 익명 계정도 같은 분기에 둡니다. 익명 세션이 붙어도 화면이 다시 만들어지지 않고 기기 일정이 그대로 보입니다.
            case .signedOut, .lockedInvalidSession, .anonymousOnline, .anonymousOfflineLimited:
                if !adultEligibility.allowsLocalUse(for: LocalGuestIdentity.storageID) {
                    adultEligibilityContent(scopeID: LocalGuestIdentity.storageID)
                } else if exposedScopeID == LocalGuestIdentity.storageID,
                          accountStoreController.activeUserID == LocalGuestIdentity.storageID,
                   let container = accountStoreController.container {
                    accountContent(container: container, userID: LocalGuestIdentity.storageID)
                } else {
                    loadingView
                }
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

    private func adultEligibilityContent(scopeID: UUID) -> some View {
        AdultEligibilityView(scopeID: scopeID)
            .id(scopeID)
            .environmentObject(authManager)
            .environmentObject(taskManager)
            .environmentObject(subscriptionManager)
            .preferredColorScheme(colorScheme)
            .environment(\.locale, Locale(identifier: appLanguage))
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
            .environmentObject(accountStoreController)
            .modelContainer(container)
            .preferredColorScheme(colorScheme)
            .task {
                guard isPresentationDemoMode || (authManager.accessState.localStorageUserID.map {
                    adultEligibility.allowsLocalUse(for: $0)
                } == true), !Task.isCancelled else { return }
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
                AlarmCoordinator.shared.isTaskCompleted = { taskId in
                    taskManager.isTaskCompleted(id: taskId)
                }
            }
            .task {
                if !isPresentationDemoMode {
                    do { try await Task.sleep(nanoseconds: 500_000_000) }
                    catch { return }
                    guard !Task.isCancelled,
                          let scopeID = authManager.accessState.localStorageUserID,
                          adultEligibility.allowsLocalUse(for: scopeID) else { return }
                    NotificationManager.shared.requestAuthorization()
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    // 익명 계정 만들기에 실패했던 기기 사용자는 앱으로 돌아올 때 다시 시도합니다.
                    if !isPresentationDemoMode {
                        Task { @MainActor in await authManager.provisionAnonymousAccountIfNeeded() }
                    }
                    // 알림·알람에서 누른 '완료'는 그날의 완료이므로 날짜 초기화보다 먼저 반영합니다.
                    // 위젯 체크는 누른 날짜에 따라 초기화 앞(어제 체크)·뒤(오늘 체크)로 나눠 반영합니다.
                    taskManager.processPendingAlarmCompletions()
                    taskManager.syncWidgetToggles()
                    taskManager.checkAndResetDailyTasks()
                    taskManager.syncWidgetToggles()
                    taskManager.rescheduleStrongTasksIfNeeded()
                    Task { @MainActor in
                        taskManager.writeWidgetSnapshot()
                        taskManager.cleanupOrphanedNotifications()
                        taskManager.refillDroppedNotifications()
                    }
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
                    .receive(on: DispatchQueue.main)
            ) { _ in
                // 앱을 켜 둔 채 자정이 지나면 포그라운드 진입이 없으므로 같은 날짜 초기화를 여기서 돌립니다.
                guard scenePhase == .active else { return }
                taskManager.processPendingAlarmCompletions()
                taskManager.syncWidgetToggles()
                taskManager.checkAndResetDailyTasks()
                taskManager.syncWidgetToggles()
                taskManager.rescheduleTasksNeedingRearm()
                taskManager.writeWidgetSnapshot()
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
        exposedScopeID = nil
        if isPresentationDemoMode {
            accountStoreController.activatePresentationStore()
            return
        }

        let expectedState = authManager.accessState
        adultEligibility.activate(
            scopeID: expectedState.localStorageUserID,
            accountID: expectedState.accountUserID,
            isOnline: authManager.canUseServerFeatures
        )

        if let userID = authManager.pendingLocalDeletionUserID {
            await removeCompletedAccountStore(for: userID)
            return
        }
        if let scopeID = expectedState.localStorageUserID,
           AdultEligibilityGatePolicy.requiresGate(auth: expectedState, status: adultEligibility.status(for: scopeID)) {
            guard accountStoreController.saveBeforeSwitch() else { return }
            await sessionCleanupCoordinator.lockLocalExposure(taskManager: taskManager, reason: .eligibilityRestricted)
            guard !Task.isCancelled, authManager.accessState == expectedState,
                  !adultEligibility.allowsLocalUse(for: scopeID) else { return }
            accountStoreController.lock()
            subscriptionManager.activateGuestScope()
            return
        }
        switch expectedState {
        case .booting:
            return

        case .authenticatedOnline(let userID),
             .authenticatedOfflineLimited(let userID):
            await sessionCleanupCoordinator.waitForPendingCleanup()
            guard !Task.isCancelled, authManager.accessState == expectedState,
                  adultEligibility.allowsLocalUse(for: userID) else { return }
            if let activeUserID = accountStoreController.activeUserID,
               activeUserID != userID {
                guard accountStoreController.saveBeforeSwitch() else { return }
                await sessionCleanupCoordinator.lockLocalExposure(
                    taskManager: taskManager,
                    reason: .accountSwitch
                )
                guard !Task.isCancelled, authManager.accessState == expectedState else { return }
                accountStoreController.lock()
            }
            guard !Task.isCancelled, authManager.accessState == expectedState else { return }
            AccountPreferences.activate(for: userID)
            WidgetAccountScope.activate(AccountPreferences.scope(for: userID))
            subscriptionManager.activateLocalAccountScope(userID)
            accountStoreController.activate(for: userID)
            exposedScopeID = userID

        case .signedOut, .lockedInvalidSession, .anonymousOnline, .anonymousOfflineLimited:
            // 익명 계정은 서버 기능에만 쓰고, 일정·알림 설정·18+ 확인·위젯은 기기 범위를 그대로 씁니다.
            await sessionCleanupCoordinator.waitForPendingCleanup()
            guard !Task.isCancelled, authManager.accessState == expectedState,
                  adultEligibility.allowsLocalUse(for: LocalGuestIdentity.storageID) else { return }
            if accountStoreController.activeUserID != LocalGuestIdentity.storageID {
                guard accountStoreController.saveBeforeSwitch() else { return }
                await sessionCleanupCoordinator.lockLocalExposure(
                    taskManager: taskManager,
                    reason: expectedState == .lockedInvalidSession ? .invalidSession : .signedOut
                )
                guard !Task.isCancelled, authManager.accessState == expectedState else { return }
                accountStoreController.lock()
            }
            guard !Task.isCancelled, authManager.accessState == expectedState else { return }
            AccountPreferences.activate(for: LocalGuestIdentity.storageID)
            WidgetAccountScope.activate(AccountPreferences.scope(for: LocalGuestIdentity.storageID))
            if expectedState.isAnonymous, let anonymousUserID = expectedState.accountUserID {
                subscriptionManager.activateLocalAccountScope(anonymousUserID, localScopeID: LocalGuestIdentity.storageID)
            } else {
                subscriptionManager.activateGuestScope()
            }
            accountStoreController.activate(for: LocalGuestIdentity.storageID)
            exposedScopeID = LocalGuestIdentity.storageID
            if expectedState == .signedOut {
                // 세션이 없고 기기 18+ 확인이 있으면 보이지 않게 익명 계정을 붙입니다. 화면은 기다리지 않습니다.
                Task { @MainActor in await authManager.provisionAnonymousAccountIfNeeded() }
            }

        case .deletionPending:
            guard accountStoreController.saveBeforeSwitch() else { return }
            await sessionCleanupCoordinator.lockLocalExposure(
                taskManager: taskManager,
                reason: .deletionPending
            )
            guard !Task.isCancelled, authManager.accessState == expectedState else { return }
            accountStoreController.lock()
        }
    }

    @MainActor
    private func removeCompletedAccountStore(for userID: UUID) async {
        guard authManager.pendingLocalDeletionUserID == userID else { return }
        exposedScopeID = nil
        if accountStoreController.activeUserID == userID {
            await sessionCleanupCoordinator.lockLocalExposure(
                taskManager: taskManager,
                reason: .deletionCompleted
            )
            guard authManager.pendingLocalDeletionUserID == userID else { return }
            accountStoreController.lock()
            await Task.yield()
        }
        guard authManager.pendingLocalDeletionUserID == userID else { return }
        accountStoreController.deleteStoreAfterServerCompletion(for: userID)
        guard accountStoreController.failureCode == nil else { return }
        AccountPreferences.removeAll(for: userID)
        adultEligibility.removeAccountRecord(for: userID)
        subscriptionManager.clearAccountCache(for: userID)
        do {
            try authManager.finishLocalAccountDeletion(for: userID)
        } catch {
            accountStoreController.markLocalDeletionFailure()
        }
    }

    @MainActor
    private func retryPersistenceOperation() {
        Task { @MainActor in
            await synchronizeAccountStoreWithAuthState()
        }
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

private struct AdultGateContext: Hashable {
    let auth: AuthAccessState
    let revision: Int
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
        ScrollView {
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

                Text(L.authRelease.deletionDelay)
                    .font(.footnote)
                    .multilineTextAlignment(.center)

                if let requestID = authManager.accountDeletionRequestID {
                    Text("\(L.authRelease.requestID): \(requestID.uuidString.lowercased())")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            if authManager.accountDeletionStatus == .completed {
                ProgressView(L.authRelease.deletionFinishing)
            } else if needsAppleReauthentication {
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
                .frame(maxWidth: 320, minHeight: 50)
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
            Link(
                L.paywall.manageSubscription,
                destination: URL(string: "https://apps.apple.com/account/subscriptions")!
            )
        }
        .padding(32)
        }
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
