import SwiftUI

// MARK: - Settings View
struct SettingsView: View {
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var taskManager: TaskManager
    @Environment(\.dismiss) private var dismiss
    
    @ObservedObject var langManager = LocalizationManager.shared
    
    @State private var showLogoutConfirm = false
    @State private var showDeleteConfirm = false
    @State private var showClearCompletedConfirm = false
    @State private var showClearAllConfirm = false

    // Notifications
    @State private var routineReminders: Bool = !UserDefaults.standard.bool(forKey: "routineRemindersDisabled")
    @State private var appointmentReminders: Bool = !UserDefaults.standard.bool(forKey: "appointmentRemindersDisabled")
    @State private var remindBefore: Int = UserDefaults.standard.integer(forKey: NotificationManager.remindBeforeKey)
    @State private var notificationSound: Bool = !UserDefaults.standard.bool(forKey: "notificationSoundDisabled")

    // Appearance
    @AppStorage("appTheme") private var appTheme: String = "system"
    @AppStorage("hapticEnabled") private var hapticEnabled: Bool = true

    // Voice
    @AppStorage("micInputMode") private var micInputMode: String = "tap"
    @AppStorage("confirmBeforeSave") private var confirmBeforeSave: Bool = true

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
                    HStack {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(DesignSystem.Colors.primary.opacity(0.6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(authManager.userEmail ?? "User")
                                .font(DesignSystem.Typography.bodyMd)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                            Text("Apple ID")
                                .font(DesignSystem.Typography.labelSm)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                        }
                    }
                    .padding(.vertical, 4)

                    Button(action: { showLogoutConfirm = true }) {
                        HStack {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                            Text(L.settings.logOut)
                        }
                        .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                    }

                    Button(action: { showDeleteConfirm = true }) {
                        HStack {
                            Image(systemName: "trash")
                            Text(L.settings.deleteAccount)
                        }
                        .foregroundColor(.red.opacity(0.7))
                    }
                } header: {
                    Text(L.settings.account)
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
                } header: {
                    Text(L.tabVoice)
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
                        UserDefaults.standard.set(!val, forKey: "routineRemindersDisabled")
                    }

                    Toggle(isOn: $appointmentReminders) {
                        HStack {
                            Image(systemName: "bell.badge")
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                            Text(L.settings.appointmentReminders)
                        }
                    }
                    .onChange(of: appointmentReminders) { _, val in
                        UserDefaults.standard.set(!val, forKey: "appointmentRemindersDisabled")
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
                        UserDefaults.standard.set(val, forKey: NotificationManager.remindBeforeKey)
                    }

                    Toggle(isOn: $notificationSound) {
                        HStack {
                            Image(systemName: "speaker.wave.2")
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                            Text(L.settings.sound)
                        }
                    }
                    .onChange(of: notificationSound) { _, val in
                        UserDefaults.standard.set(!val, forKey: "notificationSoundDisabled")
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
                    Button(action: { showClearCompletedConfirm = true }) {
                        HStack {
                            Image(systemName: "checkmark.circle")
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                            Text(L.settings.clearCompleted)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                        }
                    }

                    Button(action: { showClearAllConfirm = true }) {
                        HStack {
                            Image(systemName: "trash.circle")
                            Text(L.settings.clearAll)
                        }
                        .foregroundColor(.red.opacity(0.7))
                    }
                } header: {
                    Text(L.settings.dataManagement)
                }

                // ── About ──
                Section {
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                        Text(L.settings.version)
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                    }

                    Link(destination: URL(string: "https://waitwhat.app/privacy")!) {
                        HStack {
                            Image(systemName: "hand.raised")
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                            Text(L.settings.privacyPolicy)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12))
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.3))
                        }
                    }

                    Link(destination: URL(string: "https://waitwhat.app/terms")!) {
                        HStack {
                            Image(systemName: "doc.text")
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                            Text(L.settings.termsOfService)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12))
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.3))
                        }
                    }

                    Link(destination: URL(string: "mailto:support@waitwhat.app")!) {
                        HStack {
                            Image(systemName: "envelope")
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.5))
                            Text(L.settings.contactSupport)
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12))
                                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.3))
                        }
                    }
                } header: {
                    Text(L.settings.about)
                }
            }
            .navigationTitle(Text(verbatim: "Settings"))
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
            .alert(L.settings.deleteAccount, isPresented: $showDeleteConfirm) {
                Button(L.settings.cancel, role: .cancel) {}
                Button(L.settings.delete, role: .destructive) {
                    Task {
                        try? await authManager.deleteAccount()
                        dismiss()
                    }
                }
            } message: {
                Text(L.settings.deleteConfirm)
            }
            .alert(L.settings.clearCompleted, isPresented: $showClearCompletedConfirm) {
                Button(L.settings.cancel, role: .cancel) {}
                Button(L.settings.delete, role: .destructive) {
                    taskManager.deleteCompleted()
                }
            } message: {
                Text(L.settings.clearCompletedConfirm)
            }
            .alert(L.settings.clearAll, isPresented: $showClearAllConfirm) {
                Button(L.settings.cancel, role: .cancel) {}
                Button(L.settings.delete, role: .destructive) {
                    taskManager.deleteAll()
                }
            } message: {
                Text(L.settings.clearAllConfirm)
            }
        }
        .onChange(of: langManager.currentLanguage) { oldVal, newVal in
            // Update speech locale when language changes
            let voiceLocale = newVal.localeIdentifier
            UserDefaults.standard.set(voiceLocale, forKey: VoiceInputManager.speechLocaleKey)
            Haptic.impact(.light)
        }
    }
}
