import SwiftUI
import AuthenticationServices

// MARK: - Settings View
struct SettingsView: View {
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var taskManager: TaskManager
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject private var accountStoreController: AccountStoreController
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var langManager = LocalizationManager.shared

    @State private var showLogoutConfirm = false
    @State private var showDeleteFlow = false
    @State private var showClearCompletedConfirm = false
    @State private var showClearAllConfirm = false
    @State private var clearCompletedCount = 0
    @State private var clearAllCount = 0
    @State private var showPaywall = false
    @State private var showAIConsent = false
    @State private var aiDataConsentGranted = false
    @State private var showLogin = false
    @State private var showGuestCopyConfirmation = false
    @State private var guestCopyAccountID: UUID?
    @State private var guestCopyMessage: String?

    // Notifications
    @State private var routineReminders = true
    @State private var appointmentReminders = true
    @State private var remindBefore = 0
    @State private var notificationSound = true
    @State private var alertToneIndex = 0
    @State private var alertSwearing = false
    @State private var loadedPreferenceAccountID: UUID?
    @State private var notificationsDenied = false
    @Environment(\.scenePhase) private var scenePhase

    // Appearance
    @AppStorage("appTheme") private var appTheme: String = "system"
    @AppStorage("hapticEnabled") private var hapticEnabled: Bool = true

    // Voice
    @AppStorage("micInputMode") private var micInputMode: String = "tap"
    @State private var confirmBeforeSave = true

    /// 서버 계정 ID (익명 포함). AI 동의처럼 서버 기능에만 씁니다.
    private var accountUserID: UUID? {
        authManager.accessState.accountUserID
    }

    /// Apple로 로그인한 계정만 계정 행(이메일·복사·로그아웃·삭제)을 보여 줍니다.
    private var signedInUserID: UUID? { authManager.accessState.exposedUserID }

    private var preferenceUserID: UUID? { authManager.accessState.localStorageUserID }

    private var remindBeforeOptions: [(value: Int, label: String)] {[
        (0, L.settings.atTime),
        (5, "5 \(L.settings.minBefore)"),
        (10, "10 \(L.settings.minBefore)"),
        (15, "15 \(L.settings.minBefore)"),
        (30, "30 \(L.settings.minBefore)"),
    ]}

    var body: some View {
        NavigationView {
            // 긴 설명은 각 화면(AI 동의·계정 삭제)으로 옮기고, 여기에는 한 줄짜리 항목만 둡니다.
            // 기본 List의 회색 배경·구분선 대신 앱 배경과 카드 색을 씁니다 (DESIGN.md No-Line).
            List {
                // ── 계정 ──
                Section {
                    if signedInUserID == nil {
                        // 기기 사용자(익명 계정 포함)는 로그인하지 않습니다. 기기 행만 둡니다.
                        settingsRow(L.authRelease.guestTitle, icon: "iphone")
                        // Apple 세션이 만료된 기존 로그인 사용자만 계정 일정으로 돌아갈 길을 남깁니다.
                        if authManager.accessState == .lockedInvalidSession {
                            Text(L.authRelease.sessionExpired)
                                .font(.footnote)
                                .foregroundStyle(DesignSystem.Colors.error)
                            Button { showLogin = true } label: {
                                settingsRow(L.authRelease.signIn, icon: "person.crop.circle.badge.plus", tint: DesignSystem.Colors.primary)
                            }
                        }
                    } else {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.title2)
                                .foregroundStyle(DesignSystem.Colors.primary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(authManager.userEmail ?? L.authRelease.accountTitle)
                                    .font(DesignSystem.Typography.bodyMd)
                                    .foregroundStyle(DesignSystem.Colors.onSurface)
                                Text("Apple ID")
                                    .font(.footnote)
                                    .foregroundStyle(DesignSystem.Colors.onSurfaceMeta)
                            }
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)

                        Button {
                            guestCopyAccountID = signedInUserID
                            showGuestCopyConfirmation = true
                        } label: {
                            settingsRow(L.authRelease.copyGuestTasks, icon: "square.and.arrow.down")
                        }
                    }

                } header: {
                    Text(L.settings.account)
                }
                .settingsSectionStyle()

                // ── 구독 ──
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: subscriptionManager.isPremium ? "crown.fill" : "crown")
                            .foregroundStyle(DesignSystem.Colors.primary)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        Text(subscriptionManager.isPremium ? L.paywall.premiumActive : L.paywall.premiumInactive)
                            .foregroundStyle(DesignSystem.Colors.onSurface)
                        Spacer()
                        if subscriptionManager.isPremium {
                            Text("Mora Pro")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(DesignSystem.Colors.primary)
                        }
                    }

                    // 결제가 밀린 동안 말없이 무료로 바뀌지 않게, 무엇을 하면 되는지 함께 알려 줍니다.
                    if let billingIssue = subscriptionManager.billingIssue {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(L.paywall.billingIssueTitle, systemImage: "creditcard")
                                .font(DesignSystem.Typography.bodyMd.weight(.semibold))
                                .foregroundColor(DesignSystem.Colors.onSurface)
                            Text(billingIssue == .gracePeriod
                                 ? L.paywall.billingIssueGrace
                                 : L.paywall.billingIssuePaused)
                                .font(.footnote)
                                .foregroundColor(DesignSystem.Colors.onSurfaceMeta)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)

                        Link(destination: URL(string: "https://apps.apple.com/account/billing")!) {
                            settingsRow(L.paywall.updatePaymentMethod, icon: "creditcard", external: true)
                        }
                    }

                    if !subscriptionManager.isPremium {
                        Button { showPaywall = true } label: {
                            settingsRow(L.paywall.upgradeToPro, icon: "sparkles", tint: DesignSystem.Colors.primary, chevron: true)
                        }
                    }

                    Link(destination: URL(string: "https://apps.apple.com/account/subscriptions")!) {
                        settingsRow(L.paywall.manageSubscription, icon: "creditcard.and.123", external: true)
                    }
                } header: {
                    Text(L.paywall.subscriptionSection)
                }
                .settingsSectionStyle()

                // ── 알림 ──
                Section {
                    // 시스템에서 알림을 거부하면 아래 토글이 켜져 있어도 아무것도 울리지 않습니다.
                    if notificationsDenied {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(L.settings.notificationsOffTitle, systemImage: "bell.slash")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(DesignSystem.Colors.primary)
                            Button(L.settings.openNotificationSettings) {
                                if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(DesignSystem.Colors.primary)
                            .buttonStyle(.borderless)
                            .frame(minHeight: 44)
                        }
                        .padding(.vertical, 4)
                    }

                    Toggle(isOn: $routineReminders) {
                        settingsRow(L.settings.routineReminders, icon: "bell")
                    }
                    .onChange(of: routineReminders) { _, val in
                        if persist(!val, for: .routineRemindersDisabled) {
                            taskManager.reconcileNotificationsWithPreferences()
                        }
                    }

                    Toggle(isOn: $appointmentReminders) {
                        settingsRow(L.settings.appointmentReminders, icon: "calendar")
                    }
                    .onChange(of: appointmentReminders) { _, val in
                        if persist(!val, for: .appointmentRemindersDisabled) {
                            taskManager.reconcileNotificationsWithPreferences()
                        }
                    }

                    Picker(selection: $remindBefore) {
                        ForEach(remindBeforeOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    } label: {
                        settingsRow(L.settings.remindBefore, icon: "clock")
                    }
                    .onChange(of: remindBefore) { _, val in
                        if persist(val, for: .remindBeforeMinutes) {
                            taskManager.reconcileNotificationsWithPreferences()
                        }
                    }

                    Toggle(isOn: $notificationSound) {
                        settingsRow(L.settings.sound, icon: "speaker.wave.2")
                    }
                    .onChange(of: notificationSound) { _, val in
                        if persist(!val, for: .notificationSoundDisabled) {
                            taskManager.reconcileNotificationsWithPreferences()
                        }
                    }

                    Picker(selection: $alertToneIndex) {
                        ForEach(AlertTone.allCases, id: \.self) { tone in
                            Text(L.alertCopy.toneName(tone)).tag(tone.storageIndex)
                        }
                    } label: {
                        settingsRow(L.settings.alertTone, icon: "text.bubble")
                    }
                    .onChange(of: alertToneIndex) { _, val in
                        if persist(val, for: .alertTone) {
                            taskManager.reconcileNotificationsWithPreferences()
                        }
                    }

                    // 욕 섞기는 매운맛을 골랐을 때만 보입니다(기본 꺼짐).
                    if AlertTone(storageIndex: alertToneIndex) == .spicy {
                        Toggle(isOn: $alertSwearing) {
                            VStack(alignment: .leading, spacing: 2) {
                                settingsRow(L.settings.alertSwearing, icon: "flame")
                                if alertSwearing {
                                    Text(L.settings.alertSwearingNote)
                                        .font(.footnote)
                                        .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                                        .padding(.leading, 36)
                                }
                            }
                        }
                        .onChange(of: alertSwearing) { _, val in
                            if persist(val, for: .alertSwearing) {
                                taskManager.reconcileNotificationsWithPreferences()
                            }
                        }
                    }
                } header: {
                    Text(L.settings.notifications)
                }
                .settingsSectionStyle()

                // ── 음성 입력 ──
                Section {
                    Picker(selection: $micInputMode) {
                        Text(L.voice.micModeTap).tag("tap")
                        Text(L.voice.micModeHold).tag("hold")
                    } label: {
                        settingsRow(L.voice.micModeTitle, icon: "mic")
                    }

                    Toggle(isOn: $confirmBeforeSave) {
                        settingsRow(L.voice.confirmBeforeSave, icon: "checkmark.shield")
                    }
                    .onChange(of: confirmBeforeSave) { _, value in
                        persist(value, for: .confirmBeforeSave, default: true)
                    }

                    // AI 동의는 서버 계정(익명 포함)에 기록되므로, 그 계정이 준비된 뒤에 보입니다.
                    // 켜려고 하면 무엇이 전송되는지 보여 주는 동의 화면이 먼저 열립니다.
                    if accountUserID != nil {
                        Toggle(isOn: Binding(
                            get: { aiDataConsentGranted },
                            set: { granted in
                                if granted { showAIConsent = true }
                                else {
                                    AIDataConsent.setGranted(false, for: accountUserID)
                                    aiDataConsentGranted = false
                                }
                            }
                        )) {
                            settingsRow(L.aiPrivacy.allow, icon: "sparkles")
                        }
                    }
                } header: {
                    Text(L.settings.voiceInput)
                }
                .settingsSectionStyle()

                // ── 일반 ──
                Section {
                    Picker(selection: $langManager.currentLanguage) {
                        ForEach(AppLanguage.allCases, id: \.self) { lang in
                            Text(lang.label).tag(lang)
                        }
                    } label: {
                        settingsRow(L.settings.languageLabel, icon: "globe")
                    }

                    Picker(selection: $appTheme) {
                        Text(L.settings.systemResource).tag("system")
                        Text(L.settings.light).tag("light")
                        Text(L.settings.dark).tag("dark")
                    } label: {
                        settingsRow(L.settings.theme, icon: "circle.lefthalf.filled")
                    }

                    Toggle(isOn: $hapticEnabled) {
                        settingsRow(L.settings.haptic, icon: "hand.tap")
                    }
                } header: {
                    Text(L.settings.general)
                }
                .settingsSectionStyle()

                // ── 데이터 ──
                Section {
                    Button {
                        clearCompletedCount = taskManager.completedClearableCount()
                        showClearCompletedConfirm = true
                    } label: {
                        settingsRow(L.settings.clearCompleted, icon: "checkmark.circle")
                    }
                    .accessibilityHint(L.authRelease.clearCompletedHint)

                    Button {
                        clearAllCount = taskManager.taskCount()
                        showClearAllConfirm = true
                    } label: {
                        settingsRow(L.settings.clearAll, icon: "trash", tint: DesignSystem.Colors.error)
                    }
                    .accessibilityHint(L.authRelease.clearAllHint)
                } header: {
                    Text(L.settings.dataManagement)
                }
                .settingsSectionStyle()

                // ── 앱 정보 ──
                Section {
                    // 고객 지원은 지원 페이지 하나로 모읍니다 (문의 메일도 그 페이지에 있음).
                    Link(destination: URL(string: "https://trident-kr.github.io/waitwhat-site/")!) {
                        settingsRow(L.settings.contactSupport, icon: "questionmark.circle", external: true)
                    }
                    Link(destination: URL(string: "https://trident-kr.github.io/waitwhat-site/privacy")!) {
                        settingsRow(L.settings.privacyPolicy, icon: "hand.raised", external: true)
                    }
                    Link(destination: URL(string: "https://trident-kr.github.io/waitwhat-site/terms")!) {
                        settingsRow(L.settings.termsOfService, icon: "doc.text", external: true)
                    }
                    NavigationLink {
                        ThirdPartyNoticesView()
                    } label: {
                        settingsRow(L.authRelease.openSourceNotices, icon: "doc.plaintext")
                    }
                    settingsRow(
                        L.settings.version,
                        icon: "info.circle",
                        value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                    )
                } header: {
                    Text(L.settings.about)
                }
                .settingsSectionStyle()

                // ── 계정 나가기 (가장 아래, 위험한 동작은 끝에) ── 로그아웃은 Apple 계정만, 삭제는 익명 계정도
                if signedInUserID != nil || authManager.accessState.isAnonymous {
                    Section {
                        if signedInUserID != nil {
                            Button { showLogoutConfirm = true } label: {
                                settingsRow(L.settings.logOut, icon: "rectangle.portrait.and.arrow.right")
                            }
                            .accessibilityHint(L.authRelease.logOutHint)
                        }

                        Button { showDeleteFlow = true } label: {
                            settingsRow(L.settings.deleteAccount, icon: "person.crop.circle.badge.xmark", tint: DesignSystem.Colors.error)
                        }
                        .accessibilityHint(authManager.accessState.isAnonymous
                            ? L.authRelease.deleteAnonymousAccountHint : L.authRelease.deleteAccountHint)
                    }
                    .settingsSectionStyle()
                }
            }
            .scrollContentBackground(.hidden)
            .background(DesignSystem.Colors.background.ignoresSafeArea())
            .tint(DesignSystem.Colors.primary)
            .navigationTitle(L.authRelease.settingsTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L.settings.done) { dismiss() }
                        .foregroundColor(DesignSystem.Colors.primary)
                }
            }
            .alert(L.settings.logOut, isPresented: $showLogoutConfirm) {
                Button(L.settings.cancel, role: .cancel) {}
                Button(L.settings.logOut, role: .destructive) {
                    Task {
                        await authManager.signOut()
                        dismiss()
                    }
                }
            } message: {
                Text(L.settings.logOutConfirm)
            }
            .alert(L.settings.clearCompleted, isPresented: $showClearCompletedConfirm) {
                Button(L.settings.cancel, role: .cancel) {}
                Button(L.settings.delete, role: .destructive) {
                    taskManager.deleteCompleted()
                }
            } message: {
                Text(L.settings.clearCompletedPreview(clearCompletedCount))
            }
            .alert(L.settings.clearAll, isPresented: $showClearAllConfirm) {
                Button(L.settings.cancel, role: .cancel) {}
                Button(L.settings.delete, role: .destructive) {
                    taskManager.deleteAll()
                }
            } message: {
                Text(L.settings.clearAllPreview(clearAllCount))
            }
            .alert(L.authRelease.copyGuestTasks, isPresented: $showGuestCopyConfirmation) {
                Button(L.settings.cancel, role: .cancel) { guestCopyAccountID = nil }
                Button(L.authRelease.copyGuestTasks) { copyGuestTasks() }
            } message: {
                Text(L.authRelease.copyGuestExplanation(account: authManager.userEmail ?? L.authRelease.accountTitle))
            }
            .alert(L.authRelease.copyGuestTasks, isPresented: Binding(
                get: { guestCopyMessage != nil },
                set: { if !$0 { guestCopyMessage = nil } }
            )) {
                Button(L.settings.done) { guestCopyMessage = nil }
            } message: {
                Text(guestCopyMessage ?? "")
            }
        }
        .sheet(isPresented: $showLogin) {
            LoginView().environmentObject(authManager)
        }
        .sheet(isPresented: $showPaywall) {
            NavigationView {
                PaywallView()
                    .environmentObject(subscriptionManager)
            }
        }
        .sheet(isPresented: $showDeleteFlow) {
            AccountDeletionFlowView()
                .environmentObject(authManager)
                .environmentObject(taskManager)
                .environmentObject(subscriptionManager)
        }
        .onChange(of: langManager.currentLanguage) { oldVal, newVal in
            // Update speech locale when language changes
            let voiceLocale = newVal.localeIdentifier
            UserDefaults.standard.set(voiceLocale, forKey: VoiceInputManager.speechLocaleKey)
            // 이미 예약된 알림·위젯도 새 언어로 바꿉니다.
            taskManager.refreshForLanguageChange()
            Haptic.impact(.light)
        }
        .sheet(isPresented: $showAIConsent, onDismiss: {
            aiDataConsentGranted = AIDataConsent.isGranted(for: accountUserID)
        }) {
            AIDataConsentView(userID: accountUserID)
        }
        .onAppear(perform: loadAccountPreferences)
        .task { notificationsDenied = await NotificationManager.shared.isAuthorizationDenied() }
        .onChange(of: scenePhase) { _, phase in
            // iPhone 설정에서 알림을 켜고 돌아오면 안내를 바로 거둡니다.
            guard phase == .active else { return }
            Task { notificationsDenied = await NotificationManager.shared.isAuthorizationDenied() }
        }
        .onChange(of: preferenceUserID) { _, _ in
            loadAccountPreferences()
        }
        // 익명 계정은 같은 기기 범위에서 나중에 붙으므로, 그때 AI 동의 상태만 다시 읽습니다.
        .onChange(of: accountUserID) { _, _ in
            aiDataConsentGranted = AIDataConsent.isGranted(for: accountUserID)
        }
    }

    /// 설정 한 줄: 아이콘 + 제목 (+ 오른쪽 값·화살표). 글자는 토큰 색만 씁니다.
    private func settingsRow(
        _ title: String,
        icon: String,
        tint: Color = DesignSystem.Colors.onSurface,
        value: String? = nil,
        chevron: Bool = false,
        external: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint == DesignSystem.Colors.onSurface ? DesignSystem.Colors.primary : tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(tint)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .foregroundStyle(DesignSystem.Colors.onSurfaceMeta)
            }
            if chevron || external {
                Image(systemName: external ? "arrow.up.right" : "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.onSurfaceMeta)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    private func loadAccountPreferences() {
        aiDataConsentGranted = AIDataConsent.isGranted(for: accountUserID)
        guard let userID = preferenceUserID else {
            loadedPreferenceAccountID = nil
            routineReminders = false
            appointmentReminders = false
            remindBefore = 0
            notificationSound = false
            alertToneIndex = 0
            alertSwearing = false
            confirmBeforeSave = true
            return
        }

        routineReminders = !AccountPreferences.bool(
            .routineRemindersDisabled,
            default: false,
            for: userID
        )
        appointmentReminders = !AccountPreferences.bool(
            .appointmentRemindersDisabled,
            default: false,
            for: userID
        )
        remindBefore = AccountPreferences.integer(
            .remindBeforeMinutes,
            default: 0,
            for: userID
        )
        notificationSound = !AccountPreferences.bool(
            .notificationSoundDisabled,
            default: false,
            for: userID
        )
        confirmBeforeSave = AccountPreferences.bool(
            .confirmBeforeSave,
            default: true,
            for: userID
        )
        alertToneIndex = AccountPreferences.integer(.alertTone, default: 0, for: userID)
        alertSwearing = AccountPreferences.bool(.alertSwearing, default: false, for: userID)
        loadedPreferenceAccountID = userID
    }

    /// 저장값이 실제로 바뀐 경우에만 true입니다. 화면을 열며 저장값을 불러올 때는 onChange가 불려도
    /// 값이 같으므로 알림 재정리(받은 알림·스누즈 삭제 포함)가 돌지 않습니다.
    @discardableResult
    private func persist(_ value: Bool, for key: AccountPreferenceKey, default defaultValue: Bool = false) -> Bool {
        guard let userID = preferenceUserID,
              loadedPreferenceAccountID == userID,
              AccountPreferences.bool(key, default: defaultValue, for: userID) != value else { return false }
        AccountPreferences.set(value, for: key, userID: userID)
        return true
    }

    @discardableResult
    private func persist(_ value: Int, for key: AccountPreferenceKey) -> Bool {
        guard let userID = preferenceUserID,
              loadedPreferenceAccountID == userID,
              AccountPreferences.integer(key, default: 0, for: userID) != value else { return false }
        AccountPreferences.set(value, for: key, userID: userID)
        return true
    }

    private func copyGuestTasks() {
        defer { guestCopyAccountID = nil }
        guard let userID = guestCopyAccountID, userID == signedInUserID else {
            guestCopyMessage = L.authRelease.copyGuestFailed
            return
        }
        do {
            let count = try accountStoreController.copyGuestTasks(to: userID)
            taskManager.reconcileNotificationsWithPreferences()
            guestCopyMessage = L.authRelease.copiedGuestTasks(count)
        } catch {
            guestCopyMessage = L.authRelease.copyGuestFailed
        }
    }
}

private struct ThirdPartyNoticesView: View {
    private var notices: String {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return L.authRelease.noticesUnavailable
        }
        return text
    }

    var body: some View {
        ScrollView {
            Text(notices)
                .font(.footnote)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(L.authRelease.openSourceNotices)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AccountDeletionFlowView: View {
    @EnvironmentObject private var authManager: AuthManager
    @EnvironmentObject private var taskManager: TaskManager
    @EnvironmentObject private var subscriptionManager: SubscriptionManager
    @Environment(\.dismiss) private var dismiss

    @State private var acknowledged = false
    @State private var appleAuthorizationCode: String?
    @State private var isWorking = false
    @State private var showFinalConfirmation = false
    @State private var previewTaskCount = 0
    @State private var errorMessage: String?

    /// 로그인 없이 쓰는 익명 계정: Apple 재인증 없이 서버 기록만 지우고, 이 기기 일정은 남깁니다.
    private var isAnonymous: Bool { authManager.accessState.isAnonymous }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(isAnonymous ? L.settings.anonymousDeletionScope : L.settings.deletionPermanentLoss,
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(L.settings.deletionNoExport)
                }

                Section {
                        Text(L.settings.deletionSubscriptionNotice)
                        Link(
                            L.paywall.manageSubscription,
                            destination: URL(string: "https://apps.apple.com/account/subscriptions")!
                        )
                }

                Section {
                    Toggle(L.settings.deletionAcknowledgement, isOn: $acknowledged)
                        .onChange(of: acknowledged) { _, accepted in
                            if !accepted { appleAuthorizationCode = nil }
                        }

                    if acknowledged && !isAnonymous {
                        SignInWithAppleButton(.continue) { request in
                            authManager.prepareAppleAccountDeletionRequest(request)
                        } onCompletion: { result in
                            Task { @MainActor in
                                isWorking = true
                                defer { isWorking = false }
                                do {
                                    appleAuthorizationCode = try await authManager
                                        .reauthenticateForAccountDeletion(result)
                                    errorMessage = nil
                                } catch let error as AccountDeletionClientError {
                                    errorMessage = error.localizedDescription
                                } catch {
                                    errorMessage = L.settings.deletionTryAgain
                                }
                            }
                        }
                        .signInWithAppleButtonStyle(.black)
                        .frame(height: 50)
                        .disabled(isWorking)
                    }

                    if appleAuthorizationCode != nil {
                        Label(L.settings.deletionReauthenticationComplete, systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                    }
                } header: {
                    if !isAnonymous { Text(L.settings.deletionReauthenticate) }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        previewTaskCount = taskManager.taskCount()
                        showFinalConfirmation = true
                    } label: {
                        if isWorking {
                            ProgressView()
                        } else {
                            Text(L.settings.deletionFinalButton)
                        }
                    }
                    .disabled(!acknowledged || (!isAnonymous && appleAuthorizationCode == nil) || isWorking)
                }
            }
            .navigationTitle(L.settings.deleteAccount)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.settings.cancel) { dismiss() }
                }
            }
            .alert(L.settings.deletionFinalTitle, isPresented: $showFinalConfirmation) {
                Button(L.settings.cancel, role: .cancel) {}
                Button(L.settings.delete, role: .destructive) {
                    let code = isAnonymous ? nil : appleAuthorizationCode
                    guard acknowledged, isAnonymous || code != nil else { return }
                    appleAuthorizationCode = nil
                    Task { @MainActor in
                        isWorking = true
                        defer { isWorking = false }
                        do {
                            try await authManager.deleteAccount(appleAuthorizationCode: code)
                            dismiss()
                        } catch let error as AccountDeletionClientError {
                            errorMessage = error.localizedDescription
                        } catch {
                            errorMessage = L.settings.deletionStatusPending
                        }
                    }
                }
            } message: {
                if isAnonymous {
                    Text(L.settings.anonymousDeletionPreview)
                } else {
                    Text(L.settings.deletionFinalPreview(
                        account: authManager.userEmail ?? "Apple ID", taskCount: previewTaskCount
                    ))
                }
            }
        }
    }
}

// MARK: - Settings Section Style
private extension View {
    /// 설정 섹션: 카드 색 배경, 구분선 없음 (DESIGN.md No-Line)
    func settingsSectionStyle() -> some View {
        self
            .listRowBackground(DesignSystem.Colors.surfaceContainerLow)
            .listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
    }
}
