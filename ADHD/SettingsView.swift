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
    @ObservedObject private var adultEligibility = AdultEligibilityManager.shared

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
    @State private var showAdultEligibility = false

    // Notifications
    @State private var routineReminders = true
    @State private var appointmentReminders = true
    @State private var remindBefore = 0
    @State private var notificationSound = true
    @State private var loadedPreferenceAccountID: UUID?

    // Appearance
    @AppStorage("appTheme") private var appTheme: String = "system"
    @AppStorage("hapticEnabled") private var hapticEnabled: Bool = true

    // Voice
    @AppStorage("micInputMode") private var micInputMode: String = "tap"
    @State private var confirmBeforeSave = true

    private var accountUserID: UUID? {
        authManager.accessState.accountUserID
    }

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
            List {
                // ── Account ──
                Section {
                    if accountUserID == nil {
                        Label(L.authRelease.guestTitle, systemImage: "iphone")
                        Text(L.authRelease.guestPreserved).font(.footnote)
                        if authManager.accessState == .lockedInvalidSession {
                            Text(L.authRelease.sessionExpired).foregroundStyle(.orange)
                        }
                        Button(L.authRelease.signIn) { showLogin = true }
                    } else {
                    HStack {
                        Image(systemName: "person.circle.fill")
                            .font(.title)
                            .foregroundColor(DesignSystem.Colors.primary.opacity(0.7))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(authManager.userEmail ?? L.authRelease.accountTitle)
                                .font(DesignSystem.Typography.bodyMd)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                            Text("Apple ID")
                                .font(DesignSystem.Typography.labelSm)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.7))
                        }
                    }
                    .padding(.vertical, 4)

                    Button(action: { showLogoutConfirm = true }) {
                        HStack {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .accessibilityHidden(true)
                            Text(L.settings.logOut)
                        }
                        .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                    }
                    .accessibilityHint(L.authRelease.logOutHint)

                    Button(action: { showDeleteFlow = true }) {
                        HStack {
                            Image(systemName: "trash")
                                .accessibilityHidden(true)
                            Text(L.settings.deleteAccount)
                        }
                        .foregroundColor(.red.opacity(0.7))
                    }
                    .accessibilityHint(L.authRelease.deleteAccountHint)

                    Button(L.authRelease.copyGuestTasks) {
                        guestCopyAccountID = accountUserID
                        showGuestCopyConfirmation = true
                    }
                    Text(L.authRelease.guestPreserved).font(.footnote)
                    }
                } header: {
                    Text(L.settings.account)
                }

                // ── Subscription ──
                Section {
                    Text(L.adultEligibility.acceptedStatus)
                    Text(L.adultEligibility.settingsExplanation).font(.footnote)
                    Button(L.adultEligibility.reviewDeclaration) { showAdultEligibility = true }
                    if let error = adultEligibility.lastError {
                        Text(L.adultEligibility.error(error)).font(.footnote).foregroundStyle(.red)
                    }
                } header: { Text(L.adultEligibility.title) }

                Section {
                    HStack {
                        ZStack {
                            Circle()
                                .fill(subscriptionManager.isPremium
                                      ? DesignSystem.Colors.primary.opacity(0.15)
                                      : DesignSystem.Colors.onSurfaceVariant.opacity(0.1))
                                .frame(width: 36, height: 36)
                            Image(systemName: subscriptionManager.isPremium ? "crown.fill" : "crown")
                                .font(.system(size: 16))
                                .foregroundColor(subscriptionManager.isPremium
                                                 ? DesignSystem.Colors.primary
                                                 : DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(subscriptionManager.isPremium
                                 ? L.paywall.premiumActive
                                 : L.paywall.premiumInactive)
                                .font(DesignSystem.Typography.bodyMd)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                            if subscriptionManager.isPremium {
                                Text("Mora Pro")
                                    .font(DesignSystem.Typography.labelSm)
                                    .foregroundColor(DesignSystem.Colors.primary.opacity(0.8))
                            }
                        }
                        Spacer()
                        if subscriptionManager.isPremium {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(DesignSystem.Colors.primary)
                        }
                    }
                    .padding(.vertical, 2)

                    Link(destination: URL(string: "https://apps.apple.com/account/subscriptions")!) {
                        Label(L.paywall.manageSubscription, systemImage: "arrow.up.right.square")
                    }
                    Text(L.settings.deletionSubscriptionNotice).font(.footnote)

                    if !subscriptionManager.isPremium {
                        Button {
                            if accountUserID == nil { showLogin = true }
                            else { showPaywall = true }
                        } label: {
                            HStack {
                                Image(systemName: "sparkles")
                                    .foregroundColor(DesignSystem.Colors.primary)
                                    .accessibilityHidden(true)
                                Text(L.paywall.upgradeToPro)
                                    .foregroundColor(DesignSystem.Colors.primary)
                                    .fontWeight(.semibold)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(DesignSystem.Colors.primary.opacity(0.6))
                            }
                        }
                    }
                } header: {
                    Text(L.paywall.subscriptionSection)
                }

                // ── Language ──
                Section {
                    Picker(selection: $langManager.currentLanguage) {
                        ForEach(AppLanguage.allCases, id: \.self) { lang in
                            Text(lang.label).tag(lang)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "globe")
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                            Text(L.settings.languageLabel)
                        }
                    }
                } header: {
                    Text(L.settings.languageLabel)
                }

                // ── Voice ──
                Section {
                    Picker(selection: $micInputMode) {
                        Text(L.voice.micModeTap).tag("tap")
                        Text(L.voice.micModeHold).tag("hold")
                    } label: {
                        HStack {
                            Image(systemName: "mic.circle")
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                            Text(L.voice.micModeTitle)
                        }
                    }

                    Toggle(isOn: $confirmBeforeSave) {
                        HStack {
                            Image(systemName: "checkmark.shield")
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                            Text(L.voice.confirmBeforeSave)
                        }
                    }
                    .onChange(of: confirmBeforeSave) { _, value in
                        persist(value, for: .confirmBeforeSave)
                    }
                } header: {
                    Text(L.tabVoice)
                }

                Section {
                    Toggle(L.aiPrivacy.allow, isOn: Binding(
                        get: { aiDataConsentGranted },
                        set: { granted in
                            if granted { showAIConsent = true }
                            else {
                                AIDataConsent.setGranted(false, for: accountUserID)
                                aiDataConsentGranted = false
                            }
                        }
                    ))
                    .disabled(accountUserID == nil)
                    Text(L.aiPrivacy.choice).font(.footnote)
                    Button(L.aiPrivacy.title) { showAIConsent = true }
                        .disabled(accountUserID == nil)
                    if accountUserID == nil {
                        Button(L.authRelease.signIn) { showLogin = true }
                    }
                } header: {
                    Text(L.aiPrivacy.title)
                }

                // ── Notifications ──
                Section {
                    Toggle(isOn: $routineReminders) {
                        HStack {
                            Image(systemName: "bell")
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                            Text(L.settings.routineReminders)
                        }
                    }
                    .onChange(of: routineReminders) { _, val in
                        persist(!val, for: .routineRemindersDisabled)
                        taskManager.reconcileNotificationsWithPreferences()
                    }

                    Toggle(isOn: $appointmentReminders) {
                        HStack {
                            Image(systemName: "bell.badge")
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                            Text(L.settings.appointmentReminders)
                        }
                    }
                    .onChange(of: appointmentReminders) { _, val in
                        persist(!val, for: .appointmentRemindersDisabled)
                        taskManager.reconcileNotificationsWithPreferences()
                    }

                    Picker(selection: $remindBefore) {
                        ForEach(remindBeforeOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "clock")
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                            Text(L.settings.remindBefore)
                        }
                    }
                    .onChange(of: remindBefore) { _, val in
                        persist(val, for: .remindBeforeMinutes)
                        taskManager.reconcileNotificationsWithPreferences()
                    }

                    Toggle(isOn: $notificationSound) {
                        HStack {
                            Image(systemName: "speaker.wave.2")
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                            Text(L.settings.sound)
                        }
                    }
                    .onChange(of: notificationSound) { _, val in
                        persist(!val, for: .notificationSoundDisabled)
                        taskManager.reconcileNotificationsWithPreferences()
                    }
                } header: {
                    Text(L.settings.notifications)
                }

                // ── Appearance ──
                Section {
                    Picker(selection: $appTheme) {
                        Text(L.settings.systemResource).tag("system")
                        Text(L.settings.light).tag("light")
                        Text(L.settings.dark).tag("dark")
                    } label: {
                        HStack {
                            Image(systemName: "paintbrush")
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                            Text(L.settings.theme)
                        }
                    }

                    Toggle(isOn: $hapticEnabled) {
                        HStack {
                            Image(systemName: "hand.tap")
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                            Text(L.settings.haptic)
                        }
                    }
                } header: {
                    Text(L.settings.appearance)
                }

                // ── Data Management ──
                Section {
                    Button(action: {
                        clearCompletedCount = taskManager.taskCount(completedOnly: true)
                        showClearCompletedConfirm = true
                    }) {
                        HStack {
                            Image(systemName: "checkmark.circle")
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                                .accessibilityHidden(true)
                            Text(L.settings.clearCompleted)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                        }
                    }
                    .accessibilityHint(L.authRelease.clearCompletedHint)

                    Button(action: {
                        clearAllCount = taskManager.taskCount()
                        showClearAllConfirm = true
                    }) {
                        HStack {
                            Image(systemName: "trash.circle")
                                .accessibilityHidden(true)
                            Text(L.settings.clearAll)
                        }
                        .foregroundColor(.red.opacity(0.7))
                    }
                    .accessibilityHint(L.authRelease.clearAllHint)
                } header: {
                    Text(L.settings.dataManagement)
                }

                // ── About ──
                Section {
                    Link(L.adultEligibility.support, destination: URL(string: "https://trident-kr.github.io/waitwhat-site/")!)
                    NavigationLink {
                        ThirdPartyNoticesView()
                    } label: {
                        Label(L.authRelease.openSourceNotices, systemImage: "doc.plaintext")
                    }
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                        Text(L.settings.version)
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                    }

                    Link(destination: URL(string: "https://trident-kr.github.io/waitwhat-site/privacy")!) {
                        HStack {
                            Image(systemName: "hand.raised")
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                            Text(L.settings.privacyPolicy)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                                .accessibilityHidden(true)
                        }
                    }

                    Link(destination: URL(string: "https://trident-kr.github.io/waitwhat-site/terms")!) {
                        HStack {
                            Image(systemName: "doc.text")
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                            Text(L.settings.termsOfService)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                                .accessibilityHidden(true)
                        }
                    }

                    Link(destination: URL(string: "mailto:trident1398@gmail.com")!) {
                        HStack {
                            Image(systemName: "envelope")
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                            Text(L.settings.contactSupport)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                                .accessibilityHidden(true)
                        }
                    }
                } header: {
                    Text(L.settings.about)
                }
            }
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
        .sheet(isPresented: $showAdultEligibility) {
            if let scopeID = preferenceUserID { AdultEligibilityView(scopeID: scopeID) }
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
            Haptic.impact(.light)
        }
        .sheet(isPresented: $showAIConsent, onDismiss: {
            aiDataConsentGranted = AIDataConsent.isGranted(for: accountUserID)
        }) {
            AIDataConsentView(userID: accountUserID)
        }
        .onAppear(perform: loadAccountPreferences)
        .onChange(of: preferenceUserID) { _, _ in
            loadAccountPreferences()
        }
    }

    private func loadAccountPreferences() {
        aiDataConsentGranted = AIDataConsent.isGranted(for: accountUserID)
        guard let userID = preferenceUserID else {
            loadedPreferenceAccountID = nil
            routineReminders = false
            appointmentReminders = false
            remindBefore = 0
            notificationSound = false
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
        loadedPreferenceAccountID = userID
    }

    private func persist(_ value: Bool, for key: AccountPreferenceKey) {
        guard let userID = preferenceUserID,
              loadedPreferenceAccountID == userID else { return }
        AccountPreferences.set(value, for: key, userID: userID)
    }

    private func persist(_ value: Int, for key: AccountPreferenceKey) {
        guard let userID = preferenceUserID,
              loadedPreferenceAccountID == userID else { return }
        AccountPreferences.set(value, for: key, userID: userID)
    }

    private func copyGuestTasks() {
        defer { guestCopyAccountID = nil }
        guard let userID = guestCopyAccountID, userID == accountUserID else {
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
    var showsExactTaskCount = true
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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(L.settings.deletionPermanentLoss, systemImage: "exclamationmark.triangle.fill")
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

                    if acknowledged {
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
                    Text(L.settings.deletionReauthenticate)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        if showsExactTaskCount { previewTaskCount = taskManager.taskCount() }
                        showFinalConfirmation = true
                    } label: {
                        if isWorking {
                            ProgressView()
                        } else {
                            Text(L.settings.deletionFinalButton)
                        }
                    }
                    .disabled(!acknowledged || appleAuthorizationCode == nil || isWorking)
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
                    guard acknowledged, let code = appleAuthorizationCode else { return }
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
                if showsExactTaskCount {
                    Text(L.settings.deletionFinalPreview(
                        account: authManager.userEmail ?? "Apple ID", taskCount: previewTaskCount
                    ))
                } else {
                    Text(L.adultEligibility.deletionWithoutCount)
                }
            }
        }
    }
}
