import Foundation
import Combine
import SwiftUI
import WidgetKit

// MARK: - Localization Manager
class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()
    
    @Published var currentLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(currentLanguage.rawValue, forKey: "appLanguage")
            // 버그③: 위젯은 App Group만 읽을 수 있음 — 복제 기록 후 즉시 리로드
            UserDefaults(suiteName: appGroupID)?.set(currentLanguage.rawValue, forKey: "appLanguage")
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: "appLanguage").flatMap(AppLanguage.init(rawValue:))
        let initial = saved ?? AppLanguage.preferred()
        self.currentLanguage = initial
        if saved == nil {
            // 첫 실행: 기기 언어를 기본값으로 저장 (@AppStorage("appLanguage")도 같은 값을 읽음)
            UserDefaults.standard.set(initial.rawValue, forKey: "appLanguage")
        }
        // 앱 업데이트 직후에도 위젯이 언어를 즉시 읽을 수 있도록 App Group에 1회 시딩
        UserDefaults(suiteName: appGroupID)?.set(self.currentLanguage.rawValue, forKey: "appLanguage")
    }
    
    var strings: Strings {
        Strings(language: currentLanguage)
    }
}


/// 전역적으로 사용할 짧은 접근자
var L: Strings {
    LocalizationManager.shared.strings
}

enum AppLanguage: String, CaseIterable {
    case en, ko, ja

    var label: String {
        switch self {
        case .en: return "English"
        case .ko: return "한국어"
        case .ja: return "日本語"
        }
    }

    static var current: AppLanguage {
        LocalizationManager.shared.currentLanguage
    }
    
    /// 저장된 선택이 없을 때 기기 언어 순서에서 지원 언어를 고릅니다. 없으면 영어입니다.
    static func preferred(from identifiers: [String] = Locale.preferredLanguages) -> AppLanguage {
        for identifier in identifiers {
            let code = Locale(identifier: identifier).language.languageCode?.identifier
                ?? String(identifier.prefix(2))
            if let match = AppLanguage(rawValue: code) { return match }
        }
        return .en
    }

    var localeIdentifier: String {
        switch self {
        case .en: return "en-US"
        case .ko: return "ko-KR"
        case .ja: return "ja-JP"
        }
    }
}

struct Strings {
    let language: AppLanguage
    
    func t(_ en: String, _ ko: String, _ ja: String) -> String {
        switch language {
        case .en: return en
        case .ko: return ko
        case .ja: return ja
        }
    }

    // Tab Bar (English Fixed per Objective 1)
    var tabRoutine: String { "Routine" }
    var tabVoice:   String { "Voice" }
    var tabPlanner: String { "Planner" }

    func tabAccessibilityLabel(_ name: String) -> String { t("\(name) tab", "\(name) 탭", "\(name)タブ") }
    var tabAccessibilitySelected: String { t("Currently selected", "현재 선택됨", "選択中") }
    func tabAccessibilityHint(_ name: String) -> String { t("Double tap to switch to \(name)", "\(name)로 이동하려면 이중 탭하세요", "\(name)に切り替えるにはダブルタップ") }

    // Navigation Labels (English Fixed per Objective 1)
    var navSettings: String { "Settings" }
    var navCalendar: String { "Calendar" }

    // Offline Banner (Objective 2: Fixed to English)
    var offlineText: String { "Offline. Check your connection." }
    var backOnline:  String { "Back Online" }

    // Global
    var cancel: String { t("Cancel", "취소", "キャンセル") }
    var save:   String { t("Save", "저장", "保存") }
    var done:   String { t("Done", "완료", "完了") }
    
    // Routine Tab
    var routineTitle: String { t("My Routines", "나의 루틴", "マイルーティン") }
    var routineDailySection: String { t("Daily Routines", "매일 루틴", "デイリールーティン") }
    var routineTodaySection: String { t("Today's Tasks", "오늘 할 일", "今日のタスク") }
    var routineEmptyRoutine: String { t("Tap to add your first routine", "탭하여 첫 루틴을 추가하세요", "タップしてルーティンを追加") }
    var routineEmptyTask: String { t("Tap to add today's task", "탭하여 오늘 할 일을 추가하세요", "タップして今日のタスクを追加") }

    // Planner Tab
    var plannerTitle: String { t("My Planner", "나의 플래너", "マイプランナー") }
    var plannerEmpty: String { t("Tap to add a plan", "탭하여 일정을 추가하세요", "タップして予定を追加") }

    // Settings
    var settings: SettingsStrings { SettingsStrings(language: language) }

    // Voice Tab
    var voicePlaceholder: String { t("What should I remember for you?", "무엇을 기억해 드릴까요?", "何を覚えておきましょうか？") }
    var voiceListening: String { t("Listening...", "듣고 있어요...", "聞いています...") }
    var voiceAnalyzing: String { t("Analyzing...", "분석 중...", "分析中...") }
    var voice: VoiceStrings { VoiceStrings(language: language) }

    // Login
    var login: LoginStrings { LoginStrings(language: language) }

    // Network
    var network: NetworkStrings { NetworkStrings(language: language) }

    // Search
    var search: SearchStrings { SearchStrings(language: language) }

    // Calendar
    var calendarToday: String { t("Today", "오늘", "今日") }

    // Recurrence
    var recurrence: RecurrenceStrings { RecurrenceStrings(language: language) }

    // Paywall
    var aiPrivacy: AIPrivacyStrings { AIPrivacyStrings(language: language) }

    var paywall: PaywallStrings { PaywallStrings(language: language) }
    var quickAdd: QuickAddStrings { QuickAddStrings(language: language) }
    var onboarding: OnboardingStrings { OnboardingStrings(language: language) }
    var persistence: PersistenceStrings { PersistenceStrings(language: language) }

    // Alarm / Notification
    var alarm: AlarmStrings { AlarmStrings(language: language) }
    var alertCopy: AlertCopyStrings { AlertCopyStrings(language: language) }

    // Task Edit Sheet
    var taskEdit: TaskEditStrings { TaskEditStrings(language: language) }
}

struct PersistenceStrings {
    let language: AppLanguage
    private func t(_ en: String, _ ko: String, _ ja: String) -> String {
        switch language {
        case .en: return en
        case .ko: return ko
        case .ja: return ja
        }
    }

    var title: String {
        t("Your data couldn't be opened", "데이터를 열 수 없어요", "データを開けません")
    }

    var message: String {
        t(
            "Mora did not delete or replace your local data. Close and reopen the app. If this continues, update Mora or contact support with the code below.",
            "Mora는 로컬 데이터를 삭제하거나 교체하지 않았습니다. 앱을 종료한 뒤 다시 열어주세요. 문제가 계속되면 Mora를 업데이트하거나 아래 코드와 함께 고객 지원에 문의해주세요.",
            "Moraはローカルデータを削除・置換していません。アプリを終了して再度開いてください。問題が続く場合は、Moraを更新するか、下のコードを添えてサポートへお問い合わせください。"
        )
    }
}

struct AlarmStrings {
    let language: AppLanguage
    private func t(_ en: String, _ ko: String, _ ja: String) -> String {
        switch language {
        case .en: return en
        case .ko: return ko
        case .ja: return ja
        }
    }

    // 알림 액션
    var completeAction: String { t("Done", "완료", "完了") }
    var snoozeAction: String { t("Snooze 5 min", "5분 뒤 다시", "5分後に再通知") }

    // AlarmKit 스누즈 카운트다운 타이틀
    var countdownTitle: String { t("Snoozed", "다시 알림", "再通知") }

    // 풀스크린 오버레이 (Pro 폴백 UI)
    var overlaySubtitle: String { t("It's time. No need to rush.", "할 시간이에요. 천천히 해도 괜찮아요.", "時間です。ゆっくりで大丈夫です。") }
    var overlayConfirm: String { t("Done", "다 했어요", "完了") }
    var overlaySnooze: String { t("Remind me in 5 min", "5분 뒤 다시 알려줘요", "5分後にもう一度") }
    var overlaySnoozeA11yHint: String { t("Stops the alarm and reminds you again in 5 minutes", "알람을 끄고 5분 뒤에 다시 알려줘요", "アラームを止めて5分後にもう一度お知らせします") }
    func overlayA11yLabel(_ name: String) -> String {
        t("Alarm: \(name). It's time.",
          "알람: \(name). 할 시간이에요.",
          "アラーム: \(name)。時間です。")
    }
    func overlayA11yHint(_ name: String) -> String {
        t("Marks \(name) as done and stops the alarm",
          "\(name) 할 일을 완료로 표시하고 알람을 꺼요",
          "\(name)を完了にしてアラームを止めます")
    }
}

struct SettingsStrings {
    let language: AppLanguage
    private func t(_ en: String, _ ko: String, _ ja: String) -> String {
        switch language {
        case .en: return en
        case .ko: return ko
        case .ja: return ja
        }
    }

    var title: String { t("Settings", "설정", "設定") }
    var account: String { t("Account", "계정", "アカウント") }
    var logOut: String { t("Log Out", "로그아웃", "ログアウト") }
    var deleteAccount: String { t("Delete Account", "계정 삭제", "アカウント削除") }
    var languageLabel: String { t("Language", "언어", "言語") }
    var notifications: String { t("Notifications", "알림", "通知") }
    var notificationsOffTitle: String { t("Notifications are off", "알림이 꺼져 있어요", "通知がオフになっています") }
    var notificationsOffBody: String { t("Turn on Mora notifications in iPhone Settings so your reminders can ring.", "iPhone 설정에서 Mora 알림을 켜야 리마인더가 울려요.", "リマインダーを鳴らすには、iPhoneの設定でMoraの通知をオンにしてください。") }
    var openNotificationSettings: String { t("Open Notification Settings", "알림 설정 열기", "通知設定を開く") }
    var routineReminders: String { t("Routine Reminders", "루틴 알림", "ルーティン通知") }
    var appointmentReminders: String { t("Appointment Reminders", "일정 알림", "予定通知") }
    var remindBefore: String { t("Remind Before", "사전 알림", "事前通知") }
    var sound: String { t("Sound", "사운드", "サウンド") }
    var alertTone: String { t("Reminder Tone", "알림 말투", "通知の口調") }
    var alertSwearing: String { t("Allow Swearing", "욕 섞기", "口を悪くする") }
    var alertSwearingNote: String { t("It shows on your Lock Screen too.", "잠금 화면에도 그대로 보여요.", "ロック画面にもそのまま表示されます。") }
    var appearance: String { t("Appearance", "외관", "外観") }
    var theme: String { t("Theme", "테마", "テーマ") }
    var haptic: String { t("Haptic Feedback", "햅틱 피드백", "触覚フィードバック") }
    var dataManagement: String { t("Data Management", "데이터 관리", "データ管理") }
    var clearCompleted: String { t("Clear Completed Tasks", "완료된 태스크 삭제", "完了タスクを削除") }
    var clearAll: String { t("Clear All Data", "전체 데이터 삭제", "全データ削除") }
    var about: String { t("About", "앱 정보", "アプリ情報") }
    var general: String { t("General", "일반", "一般") }
    var voiceInput: String { t("Voice Input", "음성 입력", "音声入力") }
    var version: String { t("Version", "버전", "バージョン") }
    var privacyPolicy: String { t("Privacy Policy", "개인정보 처리방침", "プライバシーポリシー") }
    var termsOfService: String { t("Terms of Service", "이용약관", "利用規約") }
    var contactSupport: String { t("Contact Support", "고객 지원", "サポート") }
    var logOutConfirm: String { t("Are you sure you want to log out?", "로그아웃 하시겠습니까?", "ログアウトしますか？") }
    var deleteConfirm: String { t("This will permanently delete your account and all data. This action cannot be undone.", "계정과 모든 데이터가 영구 삭제됩니다. 되돌릴 수 없습니다.", "アカウントと全データが完全に削除されます。元に戻せません。") }
    var clearCompletedConfirm: String { t("Remove all completed tasks?", "완료된 태스크를 모두 삭제할까요?", "完了タスクをすべて削除しますか？") }
    var clearAllConfirm: String { t("This will delete all routines and appointments. This cannot be undone.", "모든 루틴과 일정이 삭제됩니다. 되돌릴 수 없습니다.", "全ルーティンと予定が削除されます。元に戻せません。") }
    var atTime: String { t("At time", "정시", "予定時刻") }
    var minBefore: String { t("min before", "분 전", "分前") }
    var systemResource: String { t("System", "시스템", "システム") }
    var light: String { t("Light", "라이트", "ライト") }
    var dark: String { t("Dark", "다크", "ダーク") }
    var done: String { t("Done", "완료", "完了") }
    var cancel: String { t("Cancel", "취소", "キャンセル") }
    var delete: String { t("Delete", "삭제", "削除") }
    var deletionPermanentLoss: String { t("Your Mora account, local routines, appointments, settings, and server account data will be permanently deleted.", "Mora 계정, 로컬 루틴·일정·계정 설정과 서버 계정 데이터가 영구 삭제됩니다.", "Moraアカウント、ローカルのルーティン・予定・設定、サーバー上のアカウントデータが完全に削除されます。") }
    var deletionNoExport: String { t("Mora does not offer data export in this version. This cannot be undone.", "현재 버전은 데이터 내보내기를 지원하지 않으며, 삭제 후 되돌릴 수 없습니다.", "このバージョンではデータの書き出しに対応しておらず、削除後は元に戻せません。") }
    var deletionSubscriptionNotice: String { t("Deleting Mora does not automatically cancel an App Store subscription. Deletion can continue; manage the subscription separately in Apple settings.", "Mora 계정을 삭제해도 App Store 구독은 자동 해지되지 않습니다. 삭제는 계속할 수 있으며, 구독은 Apple 설정에서 별도로 관리해 주세요.", "Moraアカウントを削除してもApp Storeのサブスクリプションは自動解約されません。削除は続行でき、サブスクリプションはAppleの設定で別途管理してください。") }
    var deletionAcknowledgement: String { t("I understand the permanent loss", "영구 삭제 내용을 확인했습니다", "完全削除の内容を確認しました") }
    var deletionReauthenticate: String { t("Reauthenticate with Apple", "Apple 재인증", "Appleで再認証") }
    var deletionReauthenticationComplete: String { t("Apple reauthentication complete", "Apple 재인증 완료", "Apple再認証完了") }
    var deletionFinalButton: String { t("Continue to final deletion", "최종 삭제로 진행", "最終削除へ進む") }
    var deletionFinalTitle: String { t("Permanently delete this exact account?", "이 계정을 영구 삭제할까요?", "このアカウントを完全に削除しますか？") }
    var deletionTryAgain: String { t("Apple reauthentication failed. Try again.", "Apple 재인증에 실패했습니다. 다시 시도해 주세요.", "Apple再認証に失敗しました。もう一度お試しください。") }
    var deletionStatusPending: String { t("The deletion request may be processing. Mora will keep the account locked and check its request ID.", "삭제 요청이 처리 중일 수 있습니다. 계정을 잠근 채 요청 ID로 상태를 확인합니다.", "削除リクエストが処理中の可能性があります。アカウントをロックし、リクエストIDで状態を確認します。") }
    var deletionPendingTitle: String { t("Deleting your account", "계정 삭제 처리 중", "アカウントを削除しています") }
    var deletionPendingMessage: String { t("Your local data is locked. Mora deletes it only after the server confirms completion.", "로컬 데이터는 잠겨 있습니다. 서버가 완료를 확인한 뒤에만 기기에서도 삭제합니다.", "ローカルデータはロックされています。サーバーで完了を確認した後にのみ端末から削除します。") }
    var checkDeletionStatus: String { t("Check deletion status", "삭제 상태 확인", "削除状態を確認") }
    func deletionFinalPreview(account: String, taskCount: Int) -> String {
        t(
            "Target: \(account)\nScope: Mora account and \(taskCount) local task(s), all types and dates\nAction: permanent deletion",
            "대상: \(account)\n범위: Mora 계정 및 로컬 태스크 \(taskCount)개, 모든 유형·날짜\n작업: 영구 삭제",
            "対象: \(account)\n範囲: Moraアカウントとローカルタスク\(taskCount)件、全種類・全日付\n操作: 完全削除"
        )
    }
    // 로그인 없이 쓰는 익명 계정: 서버 기록만 지우고, 기기에만 있는 일정은 남깁니다.
    var anonymousDeletionScope: String { t(
        "This permanently deletes Mora's server record for this device: AI usage and subscription links. Your routines and appointments stay on this device.",
        "이 기기의 Mora 서버 기록(AI 사용 기록, 구독 연결)을 영구 삭제해요. 루틴과 일정은 이 기기에 그대로 남아요.",
        "この端末のMoraサーバー記録（AIの利用記録、サブスクリプションの紐付け）を完全に削除します。ルーティンと予定はこの端末に残ります。"
    ) }
    var anonymousDeletionPreview: String { t(
        "Target: this device's Mora server record\nScope: AI usage, subscription links\nAction: permanent deletion (routines and appointments stay on this device)",
        "대상: 이 기기의 Mora 서버 기록\n범위: AI 사용 기록, 구독 연결\n작업: 영구 삭제 (루틴과 일정은 이 기기에 남아요)",
        "対象: この端末のMoraサーバー記録\n範囲: AIの利用記録、サブスクリプションの紐付け\n操作: 完全削除（ルーティンと予定はこの端末に残ります）"
    ) }
    func clearCompletedPreview(_ count: Int) -> String {
        t(
            "Deletes \(count) finished one-time appointment(s). Routines and repeating appointments stay. You can undo right after.",
            "끝난 일회성 일정 \(count)개를 지워요. 루틴과 반복 일정은 그대로 둬요. 지운 직후에는 되돌릴 수 있어요.",
            "完了した単発の予定\(count)件を削除します。ルーティンと繰り返しの予定は残ります。削除直後は元に戻せます。"
        )
    }
    func clearAllPreview(_ count: Int) -> String {
        t(
            "Target: \(count) routine/appointment task(s), all dates. Delete permanently?",
            "대상: 루틴·일정 태스크 \(count)개, 모든 날짜. 영구 삭제할까요?",
            "対象: ルーティン・予定タスク\(count)件、全日付。完全に削除しますか？"
        )
    }
}

struct VoiceStrings {
    let language: AppLanguage
    private func t(_ en: String, _ ko: String, _ ja: String) -> String {
        switch language {
        case .en: return en
        case .ko: return ko
        case .ja: return ja
        }
    }

    var errorNotHeard: String { t("Couldn't hear you. Try again?", "잘 못 들었어요. 다시 말해주세요", "聞き取れませんでした。もう一度お願いします") }
    var errorRecognitionFailed: String { t("Speech recognition failed. Try again", "음성 인식에 실패했어요. 다시 시도해주세요", "音声認識に失敗しました. 再試行してください") }
    var errorNetwork: String { t("No connection. Try again later", "연결이 없어요. 나중에 다시 시도해주세요", "接続がありません。後で再試行してください") }
    var errorApi: String { t("Something went wrong. Try again", "문제가 생겼어요. 다시 시도해주세요", "問題が発生しました。再試行してください") }
    var errorPermission: String { t("Allow the microphone in Settings, or type your task.", "설정에서 마이크를 허용하거나 글로 입력해주세요.", "設定でマイクを許可するか、文字で入力してください。") }
    var permissionReadyHint: String { t("Microphone ready. Tap again to record.", "마이크가 준비됐어요. 다시 눌러 녹음을 시작하세요.", "マイクの準備ができました。もう一度押すと録音を開始します。") }
    var errorSpeechPermission: String { t("Allow speech recognition in Settings, or type your task.", "설정에서 음성 인식을 허용하거나 글로 입력해주세요.", "設定で音声認識を許可するか、文字で入力してください。") }
    var errorSpeechRestricted: String { t("Speech recognition is restricted on this device. You can type your task.", "이 기기에서 음성 인식이 제한되어 있어요. 글로 입력할 수 있습니다.", "この端末では音声認識が制限されています。文字で入力できます。") }
    var openSettings: String { t("Open Settings", "설정 열기", "設定を開く") }
    var tryAgain: String { t("Try Again", "다시 시도", "再試行") }
    var errorTooLong: String { t("That's a bit long. Keep it under 1,000 characters.", "글이 조금 길어요. 1,000자 안으로 줄여 주세요.", "少し長すぎます。1,000文字以内にしてください。") }
    var errorSignInAgain: String { t("Please sign in again.", "다시 로그인해 주세요.", "もう一度サインインしてください。") }
    var aiUnavailable: String { t("AI isn't available right now. Please try again in a moment.", "지금은 AI를 쓸 수 없어요. 잠시 후 다시 해 주세요.", "今はAIを使えません。少ししてからもう一度お試しください。") }
    var clearDraft: String { t("Clear draft", "초안 지우기", "下書きを消す") }
    var confirmTitle: String { t("Review & Confirm", "확인 및 검토", "確認と検討") }
    var confirmUpdate: String { t("Edit", "수정", "編集") }
    
    var actionClearAll: String { t("Clear All Tasks", "모든 일정 지우기", "すべてのタスクをクリア") }
    func actionClearDate(_ date: String) -> String { t("Clear tasks for \(date)", "\(date) 일정 일괄 지우기", "\(date)のタスクを一括削除") }
    func actionPostpone(from: String, to: String) -> String { t("Postpone from \(from) to \(to)", "\(from) 일정을 \(to)로 미루기", "\(from)の予定を\(to)に延期") }
    func actionComplete(_ name: String) -> String { t("Mark \"\(name)\" as complete", "\"\(name)\" 완료 처리", "\"\(name)\"を完了にする") }
    func actionUnknown(_ cmd: String) -> String { t("Unknown command (\(cmd))", "알 수 없는 명령 (\(cmd))", "不明なコマンド (\(cmd))") }

    var guideTitle: String { t("Try saying...", "이렇게 말해보세요...", "こう言ってみてください...") }
    var guideStart: String { t("Got it, let's start", "시작하기", "始めましょう") }

    var exampleAdd: String { t("\"Take medicine at 9 AM\"", "\"오전 9시에 약 먹기\"", "\"午前9時に薬を飲む\"") }
    var exampleAppointment: String { t("\"Meeting tomorrow at 3 PM\"", "\"내일 오후 3시에 회의\"", "\"明日午後3時に会議\"") }
    var exampleDelete: String { t("\"Delete exercise\"", "\"운동 삭제\"", "\"運動を削除\"") }

    var confirmAdd: String { t("Add to", "에 추가", "に追加") }
    var confirmDelete: String { t("Delete", "삭제", "削除") }
    var confirmRoutine: String { t("Routine", "루틴", "ルーティン") }
    var confirmAppointment: String { t("Planner", "플래너", "プランナー") }
    var confirmTask: String { t("Today's Task", "오늘 할 일", "今日のタスク") }
    var confirmToday: String { t("Today", "오늘", "今日") }
    var confirmTomorrow: String { t("Tomorrow", "내일", "明日") }
    var confirmClarify: String { t("Question", "질문", "質問") }
    var confirmButton: String { t("Confirm", "확인", "確認") }
    var confirmCancel: String { t("Cancel", "취소", "キャンセル") }
    var confirmSending: String { t("Sending...", "전송 중...", "送信中...") }

    var editTaskTitle: String { t("Edit Task", "일정 수정", "タスク編集") }
    var fieldName: String { t("Task Name", "내용", "内容") }
    var fieldTime: String { t("Time", "시간", "時間") }
    var fieldDate: String { t("Date", "날짜", "日付") }
    var fieldCategory: String { t("Category", "카테고리", "カテゴリー") }
    var noTime: String { t("No time", "시간 없음", "時間なし") }
    var save: String { t("Save", "저장", "保存") }
    var cancel: String { t("Cancel", "취소", "キャンセル") }

    var preparingDraft: String { t("Preparing draft...", "초안 준비 중...", "下書きを準備中...") }
    var silenceCountdown: String { t("Draft in", "초안까지", "下書きまで") }
    var micModeTap: String { t("Tap to Toggle", "탭하여 전환", "タップして切替") }
    var micModeHold: String { t("Hold to Talk", "길게 눌러 말하기", "押し続けて話す") }
    var micModeTitle: String { t("Mic Mode", "마이크 모드", "マイクモード") }
    var confirmBeforeSave: String { t("Confirm Before Save", "저장 전 확인", "保存前に確認") }

    var undoButton: String { t("Undo", "되돌리기", "元に戻す") }
    func undoAdded(_ count: Int) -> String { t("\(count) task(s) added", "\(count)개 추가됨", "\(count)件追加") }
    func undoDeleted(_ count: Int) -> String { t("\(count) task(s) deleted", "\(count)개 삭제됨", "\(count)件削除") }
    func undoDeletedSingle(_ name: String) -> String { t("\"\(name)\" deleted", "\"\(name)\" 삭제됨", "\"\(name)\"を削除") }
    var undoCompleted: String { t("Marked as done", "완료 처리됨", "完了にしました") }
    func undoSkippedOccurrence(_ name: String) -> String { t("Skipped \"\(name)\" this time", "\"\(name)\" 이번만 건너뛰었어요", "\"\(name)\"を今回だけスキップしました") }
    var undoUncompleted: String { t("Marked as not done", "미완료 처리됨", "未完了にしました") }
    func undoUpdated(_ name: String) -> String { t("\"\(name)\" updated", "\"\(name)\" 수정됨", "「\(name)」を更新") }
    func undoBatch(_ count: Int) -> String { t("\(count) change(s) saved", "\(count)개 변경사항 저장됨", "\(count)件の変更を保存") }
    func affectedCount(_ count: Int) -> String { t("Affects \(count) task(s)", "대상 \(count)개", "対象\(count)件") }
    var reviewUpdatedPreview: String { t("The target changed. Review the updated preview and confirm again", "대상이 변경됐어요. 최신 미리보기를 확인하고 다시 승인해주세요", "対象が変更されました。最新のプレビューを確認してもう一度承認してください") }
    var partialSaveResult: String { t("Saved successful items. Review the items still shown", "성공한 항목은 저장했어요. 남은 항목을 확인해주세요", "成功した項目を保存しました。残りの項目を確認してください") }
    var noMatchingTarget: String { t("No matching task was found", "일치하는 대상을 찾지 못했어요", "一致する対象が見つかりませんでした") }
    var noMatchingTargetInline: String { t("Couldn't find this task. Tap to fix the name.", "이 일정을 찾지 못했어요. 눌러서 이름을 고칠 수 있어요.", "この予定が見つかりませんでした。タップして名前を直せます。") }
    var itemNotSaved: String { t("This item wasn't saved.", "이 항목은 저장하지 못했어요.", "この項目は保存できませんでした。") }
    func targetNames(_ names: [String], more: Int) -> String {
        let joined = names.joined(separator: ", ")
        guard more > 0 else { return joined }
        return t("\(joined) and \(more) more", "\(joined) 외 \(more)개", "\(joined) ほか\(more)件")
    }
    var saveFailedPreserved: String { t("Couldn't save. Your existing data was preserved", "저장하지 못했어요. 기존 데이터는 보존됐습니다", "保存できませんでした。既存のデータは保持されています") }
    func postponeResult(_ count: Int) -> String { t("\(count) task(s) postponed", "\(count)개 일정 연기됨", "\(count)件延期しました") }
    var postponeNone: String { t("No tasks to postpone", "연기할 일정이 없어요", "延期する予定はありません") }
    var offTopicTitle: String { t("Heads up", "알림", "お知らせ") }
    var askAgain: String { t("Ask me differently", "다시 질문하기", "もう一度話す") }

    var textInputPlaceholder: String { t("Type or edit a draft...", "초안을 입력하거나 편집하세요...", "下書きを入力・編集...") }
    var textInputSend: String { t("Send", "전송", "送信") }
    var analyzeDraft: String { t("Analyze draft", "초안 분석", "下書きを分析") }
    var analyzeDraftHint: String {
        t(
            "Double tap to analyze this draft",
            "이 초안을 분석하려면 이중 탭하세요",
            "この下書きを分析するにはダブルタップします"
        )
    }
    var editDraft: String { t("Edit", "고치기", "直す") }

    var confirmRemoveItem: String { t("Remove", "제거", "削除") }

    var a11yStartRecording: String { t("Start recording", "녹음 시작", "録音開始") }
    var a11yStopRecording: String { t("Stop recording", "녹음 중지", "録音停止") }
    var a11yTapHint: String { t("Tap to start or stop voice input", "탭하여 음성 입력을 시작하거나 중지합니다", "タップして音声入力を開始または停止") }
    var a11yHoldHint: String {
        t(
            "Hold to record and release to analyze. With VoiceOver, double tap to start or stop.",
            "길게 눌러 녹음하고 떼면 바로 분석해요. VoiceOver에서는 이중 탭하여 시작하거나 중지합니다.",
            "長押しで録音し、離すとすぐ解析します。VoiceOverではダブルタップで開始・停止します。"
        )
    }
    var a11yTabBar: String { t("Tab navigation", "탭 내비게이션", "タブナビゲーション") }
    var a11yUndo: String { t("Undo last action", "마지막 작업 되돌리기", "最後の操作を元に戻す") }

    var errorMissingDate: String { t("Check the date. It's set to today for now.", "날짜를 확인해 주세요. 우선 오늘로 맞춰 뒀어요.", "日付を確認してください。ひとまず今日にしています。") }
    var errorBusy: String { t("Lots of requests right now. Please try again in a moment.", "잠깐 요청이 몰렸어요. 조금 뒤에 다시 해 주세요.", "リクエストが集中しています。少し時間をおいてからもう一度お試しください。") }

    var urgencyStrong: String { t("Firm reminder", "꼭 알림", "しっかり通知") }
    var urgencyWeak: String { t("Gentle reminder", "살짝 알림", "そっと通知") }
}

struct LoginStrings {
    let language: AppLanguage
    private func t(_ en: String, _ ko: String, _ ja: String) -> String {
        switch language {
        case .en: return en
        case .ko: return ko
        case .ja: return ja
        }
    }
    var subtitle: String { t("Your AI thoughts companion.", "당신의 AI 생각 도우미.", "あなたのAI思考パートナー。") }
    var tosPrefix: String { t("By signing in, you agree to our ", "로그인하면 ", "サインインすると") }
    var tosLink: String { t("Terms of Service", "이용약관", "利用規約") }
    var tosSuffix: String { t(".", "에 동의합니다.", "に同意します。") }
}

struct NetworkStrings {
    let language: AppLanguage
    private func t(_ en: String, _ ko: String, _ ja: String) -> String {
        switch language {
        case .en: return en
        case .ko: return ko
        case .ja: return ja
        }
    }
    var backOnline: String { t("Back online ✓", "온라인 복구 ✓", "オンラインに復帰 ✓") }
}

struct RecurrenceStrings {
    let language: AppLanguage
    private func t(_ en: String, _ ko: String, _ ja: String) -> String {
        switch language {
        case .en: return en
        case .ko: return ko
        case .ja: return ja
        }
    }
    var weekly: String { t("Weekly", "매주", "毎週") }
    var biweekly: String { t("Biweekly", "격주", "隔週") }
    var monthly: String { t("Monthly", "매월", "毎月") }
    var yearly: String { t("Yearly", "매년", "毎年") }
}

struct SearchStrings {
    let language: AppLanguage
    private func t(_ en: String, _ ko: String, _ ja: String) -> String {
        switch language {
        case .en: return en
        case .ko: return ko
        case .ja: return ja
        }
    }
    var title: String { t("Search", "검색", "検索") }
    var placeholder: String { t("Search tasks...", "할 일 검색...", "タスクを検索...") }
    var noResults: String { t("No results found", "검색 결과 없음", "結果が見つかりません") }
    var hint: String { t("Search your routines and plans", "루틴과 일정을 검색하세요", "ルーティンと予定を検索") }
}

struct OnboardingStrings {
    let language: AppLanguage
    private func t(_ en: String, _ ko: String, _ ja: String) -> String {
        switch language {
        case .en: return en
        case .ko: return ko
        case .ja: return ja
        }
    }

    func pageHint(_ page: Int, total: Int) -> String {
        t("Page \(page) of \(total)", "전체 \(total)페이지 중 \(page)페이지", "全\(total)ページ中\(page)ページ")
    }

    var page1Title: String { t("Just say it.", "말하면 끝.", "話すだけ。") }
    var page1Body: String { t("One mic for every routine,\ntask, and plan.", "루틴, 할 일, 일정까지\n마이크 하나로 전부.", "ルーティンも予定も\nマイクひとつで全部。") }
    var page2Title: String { t("Say it\nlike this.", "이렇게\n말해보세요.", "たとえば、\nこんなふうに。") }

    /// 2장 대화 예시: 사용자가 한 말과 Mora가 정리한 결과 (name은 굵게, detail은 이어서 보통 굵기)
    struct Example: Hashable {
        let said: String
        let name: String
        let detail: String
    }

    var examples: [Example] {
        switch language {
        case .en: return [
            Example(said: "Meeting tomorrow at 3pm", name: "Meeting", detail: " · Tomorrow, 3:00 PM"),
            Example(said: "Take my meds every day at 9am", name: "Take meds", detail: " · Daily, 9:00 AM"),
            Example(said: "Delete workout", name: "Workout", detail: " deleted"),
        ]
        case .ko: return [
            Example(said: "내일 오후 3시에 회의", name: "회의", detail: " · 내일 오후 3:00"),
            Example(said: "매일 아침 9시에 약 먹기", name: "약 먹기", detail: " · 매일 오전 9:00"),
            Example(said: "운동은 지워줘", name: "운동", detail: "을 지웠어요"),
        ]
        case .ja: return [
            Example(said: "明日の15時に会議", name: "会議", detail: " · 明日 15:00"),
            Example(said: "毎朝9時に薬を飲む", name: "薬を飲む", detail: " · 毎日 9:00"),
            Example(said: "運動は消して", name: "運動", detail: "を削除しました"),
        ]
        }
    }

    var start: String { t("Get started", "시작하기", "はじめる") }
    var next: String { t("Next", "다음", "次へ") }
    var skip: String { t("Skip", "건너뛰기", "スキップ") }
}

struct QuickAddStrings {
    let language: AppLanguage
    private func t(_ en: String, _ ko: String, _ ja: String) -> String {
        switch language {
        case .en: return en
        case .ko: return ko
        case .ja: return ja
        }
    }

    var title: String { t("Quick Add", "빠른 추가", "クイック追加") }
    var save: String { t("Add", "추가", "追加") }
    var saveFailed: String {
        t("Couldn't save. Please tap Add again in a moment.",
          "저장하지 못했어요. 잠시 후 다시 눌러 주세요.",
          "保存できませんでした。少し待ってからもう一度押してください。")
    }
}

struct PaywallStrings {
    let language: AppLanguage
    private func t(_ en: String, _ ko: String, _ ja: String) -> String {
        switch language {
        case .en: return en
        case .ko: return ko
        case .ja: return ja
        }
    }

    var title: String { t("Mora Pro", "Mora Pro", "Mora Pro") }
    var subtitle: String { t("More room for AI task planning,\nwith advanced reminders and task widgets.", "AI 일정 입력을 더 자유롭게,\n고급 알림과 일정 위젯까지.", "AIで予定をもっと自由に。\n高度なリマインダーとタスクウィジェットも。") }
    var purchaseErrorTitle: String { t("Purchase Error", "구매 오류", "購入エラー") }
    var restoreErrorTitle: String { t("Restore Error", "복원 오류", "復元エラー") }
    var ok: String { t("OK", "확인", "OK") }
    var choosePlan: String { t("CHOOSE YOUR PLAN", "플랜 선택", "プランを選択") }
    var planMonthly: String { t("Monthly", "월간", "月額") }
    var planYearly: String { t("Yearly", "연간", "年額") }
    var billedMonthly: String { t("Billed monthly", "매월 청구", "毎月請求") }
    var billedAnnually: String { t("Billed annually", "연 1회 청구", "年1回請求") }
    /// VoiceOver용 플랜 카드 한 줄: 이름, 가격, 청구 주기
    func planAccessibilityLabel(name: String, price: String, period: String, badge: String?) -> String {
        [name, price, period, badge].compactMap { $0 }.joined(separator: t(", ", ", ", "、"))
    }
    func billedYearly(monthlyEquivalent: String) -> String {
        t(
            "Billed annually · \(monthlyEquivalent)/mo",
            "연 1회 청구 · 월 \(monthlyEquivalent)",
            "年1回請求 · 月\(monthlyEquivalent)"
        )
    }
    func savePercent(_ percent: Int) -> String { t("Save \(percent)%", "\(percent)% 절약", "\(percent)%お得") }
    var subscribe: String { t("Subscribe", "구독하기", "登録する") }
    var startSubscription: String { t("Start Pro", "Pro 시작하기", "Pro を開始") }
    var restore: String { t("Restore Purchases", "구매 복원", "購入を復元") }
    var loadingPlans: String { t("Loading plans...", "플랜 불러오는 중...", "プランを読み込み中...") }
    var loadPlansFailed: String { t("Failed to load plans.", "플랜을 불러오지 못했어요.", "プランの読み込みに失敗しました。") }
    var retry: String { t("Retry", "다시 시도", "再試行") }
    var legalNote: String { t(
        "Payment is charged to your Apple Account when you confirm the purchase. The subscription renews automatically unless auto-renew is turned off at least 24 hours before the current period ends, and the renewal is charged within 24 hours before the period ends. Manage or cancel anytime in your Apple Account subscription settings.",
        "결제는 구매를 확인하면 Apple 계정으로 청구돼요. 현재 기간이 끝나기 최소 24시간 전에 자동 갱신을 끄지 않으면 구독이 자동으로 갱신되고, 갱신 요금은 기간이 끝나기 전 24시간 안에 청구돼요. 구독 관리와 해지는 언제든 Apple 계정의 구독 설정에서 할 수 있어요.",
        "お支払いは購入の確定時にAppleアカウントに請求されます。現在の期間が終了する24時間前までに自動更新をオフにしない限り、サブスクリプションは自動的に更新され、更新料金は期間終了前の24時間以内に請求されます。管理や解約は、Appleアカウントのサブスクリプション設定からいつでも行えます。"
    ) }

    var featureVoiceTitle: String { t("AI beyond the daily free limit", "AI 일일 무료 횟수 제한 해제", "AIの1日の無料回数制限を解除") }
    var featureVoiceDesc: String { t("Free includes 3 AI analyses per day. Pro removes this daily limit. Excessive requests may be temporarily limited to keep the service available.", "무료 AI 분석은 하루 3회입니다. Pro는 이 일일 횟수 제한을 해제합니다. 안정적인 서비스 운영을 위해 과도한 요청은 일시적으로 제한될 수 있어요.", "無料のAI分析は1日3回です。Proではこの1日の回数制限を解除します。安定したサービス提供のため、過剰なリクエストは一時的に制限される場合があります。") }
    var featureAlarmsTitle: String { t("Full-screen alarms", "전체 화면 알람", "フルスクリーンアラーム") }
    var featureAlarmsDesc: String { t("Firm reminders show up full-screen, with Done and Snooze right there. Delivery depends on device permissions and settings.", "꼭 알림은 전체 화면으로 알려 주고, 완료와 다시 알림을 바로 누를 수 있어요. 전달은 기기 권한과 설정에 따라 달라져요.", "しっかり通知は全画面で表示され、完了とスヌーズをすぐ操作できます。通知は端末の許可と設定によって異なります。") }
    var featureWidgetsTitle: String { t("Home screen widgets", "홈 화면 위젯", "ホーム画面ウィジェット") }
    var featureWidgetsDesc: String { t("See your next task and routine progress from Home and Lock Screen task widgets with Pro.", "Pro 일정 위젯에서 다음 할 일과 루틴 진행 상황을 홈·잠금 화면으로 확인하세요.", "Proのタスクウィジェットで、次のタスクやルーティンの進捗をホーム・ロック画面から確認できます。") }

    var purchasePending: String { t("Your purchase is awaiting approval. Pro will activate after Apple and Mora confirm it.", "구매 승인을 기다리고 있어요. Apple과 Mora의 확인이 끝나면 Pro가 활성화됩니다.", "購入は承認待ちです。AppleとMoraの確認後にProが有効になります。") }
    var connectionRequired: String { t("Connect to the internet to subscribe or restore purchases.", "구독하거나 구매를 복원하려면 인터넷에 연결해 주세요.", "登録や購入の復元にはインターネット接続が必要です。") }
    var registrationUnavailable: String { t("Subscription verification is unavailable. No purchase was started. Please try again later.", "구독 확인을 사용할 수 없어 결제를 시작하지 않았어요. 잠시 후 다시 시도해 주세요.", "サブスクリプションを確認できないため、購入は開始していません。しばらくしてからお試しください。") }
    var restoreRebindUnavailable: String { t("This subscription cannot be restored to the current account. Please contact support.", "이 구독을 현재 계정으로 복원할 수 없어요. 고객 지원에 문의해 주세요.", "このアカウントにはサブスクリプションを復元できません。サポートにお問い合わせください。") }
    var ownedByAnotherAccount: String { t("This subscription is linked to another Mora account. Please contact support.", "이 구독은 다른 Mora 계정에 연결되어 있어요. 고객 지원에 문의해 주세요.", "このサブスクリプションは別のMoraアカウントに紐づいています。サポートにお問い合わせください。") }
    var familySharingUnsupported: String { t("Subscriptions received through Family Sharing are not supported.", "가족 공유로 받은 구독은 지원하지 않아요.", "ファミリー共有で受け取ったサブスクリプションには対応していません。") }
    var verificationFailed: String { t("The subscription could not be verified. Please try again later.", "구독 정보를 확인할 수 없어요. 잠시 후 다시 시도해 주세요.", "サブスクリプションを確認できませんでした。しばらくしてからお試しください。") }
    var nothingToRestore: String { t("No active subscription was found to restore.", "복원할 수 있는 활성 구독을 찾지 못했어요.", "復元できる有効なサブスクリプションが見つかりませんでした。") }
    var accountTokenChanged: String { t("The subscription account could not be confirmed. Please contact support.", "구독 계정을 확인할 수 없어요. 고객 지원에 문의해 주세요.", "サブスクリプションのアカウントを確認できませんでした。サポートにお問い合わせください。") }
    var entitlementNotGranted: String { t("Your purchase was received, but Pro access has not been confirmed. Try Restore Purchases before buying again, or contact support.", "구매 정보는 받았지만 Pro 권한을 확인하지 못했어요. 다시 결제하기 전에 구매 복원을 시도하거나 고객 지원에 문의해 주세요.", "購入情報は受信しましたが、Proの利用権限を確認できませんでした。再購入の前に購入を復元するか、サポートにお問い合わせください。") }
    var paymentNotStarted: String { t("Payment didn't start. Please try again in a moment.", "결제는 시작되지 않았어요. 잠시 후 다시 시도해 주세요.", "お支払いは開始されていません。しばらくしてからもう一度お試しください。") }
    var restoreFailed: String { t("Couldn't restore your purchase. Please try again in a moment.", "구매를 복원하지 못했어요. 잠시 후 다시 시도해 주세요.", "購入を復元できませんでした。しばらくしてからもう一度お試しください。") }
    var serverUnavailable: String { t("We could not confirm your subscription. Check your connection and try Restore Purchases before buying again.", "구독 상태를 확인하지 못했어요. 연결을 확인하고, 다시 결제하기 전에 구매 복원을 시도해 주세요.", "サブスクリプションを確認できませんでした。接続を確認し、再購入の前に購入の復元をお試しください。") }

    var subscriptionSection: String { t("Subscription", "구독", "サブスクリプション") }
    var premiumActive: String { t("Pro · Active", "Pro · 활성", "Pro · 有効") }
    var premiumInactive: String { t("Free Plan", "무료 플랜", "無料プラン") }
    var upgradeToPro: String { t("Upgrade to Pro", "Pro로 업그레이드", "Proにアップグレード") }
    var manageSubscription: String { t("Manage Subscription", "구독 관리", "サブスクリプション管理") }
    var billingIssueTitle: String { t("Your payment didn't go through", "결제가 되지 않았어요", "お支払いが完了していません") }
    var billingIssueGrace: String {
        t("Pro stays on for now. Update your payment method in the App Store to keep it.",
          "지금은 Pro를 그대로 쓸 수 있어요. App Store에서 결제 수단을 바꾸면 계속 이어져요.",
          "いまはProをそのまま使えます。App Storeでお支払い方法を更新すると引き続き使えます。")
    }
    var billingIssuePaused: String {
        t("Pro is paused for now. Update your payment method in the App Store and it'll turn back on.",
          "Pro가 잠시 멈췄어요. App Store에서 결제 수단을 바꾸면 다시 켜져요.",
          "Proを一時停止しています。App Storeでお支払い方法を更新すると再開します。")
    }
    var updatePaymentMethod: String { t("Update Payment Method", "결제 수단 바꾸기", "お支払い方法を更新") }
}

struct AIPrivacyStrings {
    let language: AppLanguage
    private func t(_ en: String, _ ko: String, _ ja: String) -> String {
        switch language { case .en: return en; case .ko: return ko; case .ja: return ja }
    }
    var title: String { t("AI data sharing", "AI 데이터 전송", "AIへのデータ送信") }
    var explanation: String { t(
        "When you finish speaking or tap Send, your speech transcript or typed text, current date/time and app language are sent through Supabase to Anthropic Claude first, and to Google Gemini if Claude is unavailable or cannot return a valid result to interpret your request. Your full task list and raw audio are not sent to either AI provider. Voice transcription uses Apple's speech recognition and may be processed by Apple. Speech is sent as soon as you finish speaking, so avoid including sensitive information.",
        "말을 마치거나 보내기를 누르면 음성 인식 문장 또는 입력한 글, 현재 날짜·시간과 앱 언어가 Supabase 서버를 거쳐 먼저 Anthropic Claude로 전달됩니다. Claude를 사용할 수 없거나 올바른 결과를 받지 못하면 Google Gemini로 전달해 요청을 해석합니다. 전체 일정 목록과 원본 음성은 두 AI 제공자 모두에게 보내지 않습니다. 음성 전사는 Apple 음성 인식을 사용하며 Apple에서 처리될 수 있습니다. 음성은 말을 마치면 바로 전송되니 민감한 정보는 포함하지 마세요.",
        "話し終えるか送信を押すと、音声を文字にした文章または入力した文章、現在の日時とアプリの言語がSupabase経由でまずAnthropic Claudeに送信します。Claudeが利用できない場合や有効な結果を得られない場合は、Google Geminiに送信して解析します。タスク一覧全体や音声そのものはどちらのAI提供者にも送信しません。音声の文字起こしにはAppleの音声認識を使用し、Appleで処理される場合があります。音声は話し終えるとすぐ送信されるため、機密情報は含めないでください。"
    ) }
    var choice: String { t(
        "AI is optional. You can add and edit tasks manually without sharing them with either AI provider. You can withdraw permission in Settings. Withdrawal stops future AI requests; it does not recall data already sent. See the privacy policies for data handling and retention.",
        "AI 사용은 선택입니다. AI 전송에 동의하지 않아도 일정을 직접 추가·수정할 수 있습니다. 설정에서 언제든 동의를 철회할 수 있으며, 철회하면 이후 AI 요청이 중단됩니다. 이미 보낸 데이터는 회수되지 않습니다. 데이터 처리와 보관은 개인정보 처리방침을 확인하세요.",
        "AIの利用は任意です。同意しなくてもタスクを手動で追加・編集できます。設定でいつでも同意を撤回でき、以後のAIリクエストは停止します。送信済みのデータは取り戻せません。データの取り扱いと保管はプライバシーポリシーをご確認ください。"
    ) }
    var allow: String { t("Allow AI data sharing", "AI 데이터 전송에 동의", "AIへの送信に同意する") }
    var notNow: String { t("Not now", "나중에", "あとで") }
    /// 동의 시트의 동의 버튼. 제목 없이 이 버튼 이름이 무엇에 동의하는지 말합니다.
    var agree: String { t("Allow AI", "AI 사용 동의", "AIの利用に同意") }
    var details: String { t("Details", "자세히 보기", "詳しく見る") }
    /// 보낼 글이 없을 때(설정에서 열 때) 흐름 그림에 보여 줄 예시
    var sampleDraft: String { t("Dentist at 3pm", "내일 오후 3시에 치과", "明日15時に歯医者") }
    var flowAccessibility: String { t("Your text is sent to Claude, or to Gemini if Claude is unavailable", "적은 글을 Claude에 보내요. Claude가 안 되면 Gemini에 보내요", "入力した文章をClaudeに送ります。Claudeが使えない場合はGeminiに送ります") }
    func quoted(_ text: String) -> String { t("“\(text)”", "“\(text)”", "「\(text)」") }
    var anthropicPolicy: String { t("Anthropic data policy", "Anthropic 데이터 정책", "Anthropicのデータポリシー") }
    var googlePolicy: String { t("Google Gemini data policy", "Google Gemini 데이터 정책", "Google Geminiのデータポリシー") }
}

// MARK: - Task Edit Sheet
/// 루틴·일정 수정 시트와 반복 일정 삭제 확인에 쓰는 문구
struct TaskEditStrings {
    let language: AppLanguage
    private func t(_ en: String, _ ko: String, _ ja: String) -> String {
        switch language {
        case .en: return en
        case .ko: return ko
        case .ja: return ja
        }
    }

    var editRoutine: String { t("Edit routine", "루틴 수정", "ルーティンを編集") }
    var editAppointment: String { t("Edit appointment", "일정 수정", "予定を編集") }
    var namePlaceholder: String { t("Task name", "할 일 이름", "タスク名") }

    var date: String { t("Date", "날짜", "日付") }
    var startDate: String { t("Starts", "시작일", "開始日") }
    var time: String { t("Time", "시간", "時刻") }
    var setTime: String { t("Set a time", "시간 정하기", "時刻を設定") }
    var noTime: String { t("No time", "시간 없음", "時刻なし") }
    var repeatTitle: String { t("Repeat", "반복", "繰り返し") }
    var repeatNever: String { t("Never", "안 함", "しない") }
    var repeatBiweekly: String { t("Every 2 weeks", "격주", "隔週") }
    var reminder: String { t("Reminder", "알림", "通知") }
    var reminderHelp: String {
        t("Firm rings like an alarm. Gentle shows a quiet banner.",
          "꼭 알림은 알람처럼 울리고, 살짝 알림은 조용히 알려 줘요.",
          "しっかり通知はアラームのように鳴り、そっと通知は静かにお知らせします。")
    }
    var delete: String { t("Delete", "삭제", "削除") }

    // 반복 일정 삭제: 이번만 건너뛰기 / 모든 회차 삭제
    var repeatingDeleteTitle: String { t("This one repeats", "반복되는 일정이에요", "繰り返しの予定です") }
    var repeatingDeleteMessage: String {
        t("You can skip just this one and keep the rest.",
          "이번 한 번만 건너뛰고 나머지는 그대로 둘 수 있어요.",
          "今回だけスキップして、ほかはそのまま残せます。")
    }
    var skipThisOne: String { t("Skip just this one", "이번만 건너뛰기", "今回だけスキップ") }
    var deleteAll: String { t("Delete all", "모든 회차 삭제", "すべて削除") }

    /// 다른 날 보고 있는 반복 일정의 체크 원 (완료 표시는 그날 할 수 있음)
    var checkOffOnTheDay: String {
        t("You can check this off on the day",
          "그날이 되면 완료로 표시할 수 있어요",
          "当日になったら完了にできます")
    }
}

// MARK: - Alert Tone
/// 알림 말투. 설정의 '알림 말투'에서 고르고, AI가 알림 문장을 쓸 때도 이 말투로 씁니다.
/// rawValue는 서버(analyze-task)에 그대로 보내므로 바꾸지 않습니다.
enum AlertTone: String, CaseIterable, Sendable {
    case gentle, buddy, nudge, spicy

    /// 설정에 저장하는 순서 값입니다(AccountPreferences는 정수로 저장).
    var storageIndex: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    init(storageIndex: Int) {
        self = Self.allCases.indices.contains(storageIndex) ? Self.allCases[storageIndex] : .gentle
    }
}

/// 알림이 울리는 차례입니다. 처음, 안 했을 때 5분·10분 뒤, '5분 뒤 다시'를 누른 뒤.
enum AlertStage: Sendable {
    case first, followUp1, followUp2, snooze
}

/// 잠금 화면에 보이는 한 줄짜리 알림 문장입니다.
/// AI가 써 준 문장이 없을 때(빠른 추가, 간단한 문장, 말투를 바꾼 뒤) 할 일 이름을 넣어 이 문장을 씁니다.
struct AlertCopyStrings {
    let language: AppLanguage

    func line(_ stage: AlertStage, tone: AlertTone, swearing: Bool, task: String) -> String {
        if tone == .spicy && swearing { return swear(stage, task) }
        switch language {
        case .en: return en(stage, tone, task)
        case .ko: return ko(stage, tone, task)
        case .ja: return ja(stage, tone, task)
        }
    }

    func toneName(_ tone: AlertTone) -> String {
        switch (tone, language) {
        case (.gentle, .en): return "Gentle"
        case (.gentle, .ko): return "다정하게"
        case (.gentle, .ja): return "やさしく"
        case (.buddy, .en): return "Buddy"
        case (.buddy, .ko): return "친구처럼"
        case (.buddy, .ja): return "友だち風"
        case (.nudge, .en): return "Nudge"
        case (.nudge, .ko): return "살살"
        case (.nudge, .ja): return "そっと"
        case (.spicy, .en): return "Spicy"
        case (.spicy, .ko): return "매운맛"
        case (.spicy, .ja): return "激辛"
        }
    }

    private func ko(_ stage: AlertStage, _ tone: AlertTone, _ t: String) -> String {
        switch (tone, stage) {
        case (.gentle, .first): return "\(t) 시간이에요"
        case (.gentle, .followUp1): return "\(t), 아직이에요? 천천히 해도 돼요"
        case (.gentle, .followUp2): return "\(t), 지금 해도 늦지 않아요"
        case (.gentle, .snooze): return "\(t), 다시 알려드려요"
        case (.buddy, .first): return "\(t) 시간이야!"
        case (.buddy, .followUp1): return "\(t) 아직이지? 얼른 하고 와"
        case (.buddy, .followUp2): return "\(t)! 이번엔 진짜야"
        case (.buddy, .snooze): return "\(t), 나 또 왔어!"
        case (.nudge, .first): return "\(t), 지금 시작해볼까요?"
        case (.nudge, .followUp1): return "\(t), 딱 1분만 해볼까요?"
        case (.nudge, .followUp2): return "\(t), 지금 해두면 편해요"
        case (.nudge, .snooze): return "\(t), 이제 해볼까요?"
        case (.spicy, .first): return "\(t). 지금."
        case (.spicy, .followUp1): return "\(t) 아직도 안 했냐?"
        case (.spicy, .followUp2): return "마지막 경고. \(t)."
        case (.spicy, .snooze): return "\(t). 또 미루지 마."
        }
    }

    private func en(_ stage: AlertStage, _ tone: AlertTone, _ t: String) -> String {
        switch (tone, stage) {
        case (.gentle, .first): return "Time for \(t)"
        case (.gentle, .followUp1): return "\(t): still there? No rush."
        case (.gentle, .followUp2): return "\(t): now's still a good time"
        case (.gentle, .snooze): return "\(t), here again"
        case (.buddy, .first): return "\(t) time!"
        case (.buddy, .followUp1): return "\(t) yet? Go do it."
        case (.buddy, .followUp2): return "\(t)! For real this time."
        case (.buddy, .snooze): return "Me again! \(t)"
        case (.nudge, .first): return "\(t)? Let's give it a go."
        case (.nudge, .followUp1): return "\(t), just one minute?"
        case (.nudge, .followUp2): return "\(t) now, easier later"
        case (.nudge, .snooze): return "\(t), ready now?"
        case (.spicy, .first): return "\(t). Now."
        case (.spicy, .followUp1): return "\(t). Still waiting."
        case (.spicy, .followUp2): return "Final warning: \(t)."
        case (.spicy, .snooze): return "\(t). Stop stalling."
        }
    }

    private func ja(_ stage: AlertStage, _ tone: AlertTone, _ t: String) -> String {
        switch (tone, stage) {
        case (.gentle, .first): return "\(t)の時間です"
        case (.gentle, .followUp1): return "\(t)、まだですか？ゆっくりで大丈夫"
        case (.gentle, .followUp2): return "\(t)、今からでも間に合います"
        case (.gentle, .snooze): return "\(t)、もう一度お知らせします"
        case (.buddy, .first): return "\(t)の時間だよ！"
        case (.buddy, .followUp1): return "\(t)まだ？早くやっちゃお"
        case (.buddy, .followUp2): return "\(t)！今度こそね"
        case (.buddy, .snooze): return "\(t)、また来たよ！"
        case (.nudge, .first): return "\(t)、始めてみませんか？"
        case (.nudge, .followUp1): return "\(t)、1分だけやってみる？"
        case (.nudge, .followUp2): return "\(t)、今やると後が楽です"
        case (.nudge, .snooze): return "\(t)、そろそろどうですか？"
        case (.spicy, .first): return "\(t)。今すぐ。"
        case (.spicy, .followUp1): return "\(t)、まだやってないの？"
        case (.spicy, .followUp2): return "最終警告。\(t)。"
        case (.spicy, .snooze): return "\(t)。先延ばし禁止。"
        }
    }

    /// 매운맛 + 욕 섞기(기본 꺼짐). AI에게 맡기지 않고 늘 이 문장을 씁니다.
    private func swear(_ stage: AlertStage, _ t: String) -> String {
        switch (language, stage) {
        case (.ko, .first): return "\(t). 당장 해, 이 새끼야"
        case (.ko, .followUp1): return "야, \(t) 아직도 안 했냐? 씨발"
        case (.ko, .followUp2): return "\(t). 제발 좀 해라, 이 개새끼야"
        case (.ko, .snooze): return "\(t). 또 미루냐, 이 새끼가"
        case (.en, .first): return "\(t). Now, dammit."
        case (.en, .followUp1): return "\(t). What the hell are you waiting for?"
        case (.en, .followUp2): return "Last fucking warning: \(t)."
        case (.en, .snooze): return "\(t). Quit stalling, dumbass."
        case (.ja, .first): return "\(t)。さっさとやれ、このバカ"
        case (.ja, .followUp1): return "\(t)まだかよ、クソが"
        case (.ja, .followUp2): return "\(t)。いい加減にしろ、このアホ"
        case (.ja, .snooze): return "\(t)。また逃げる気か、ボケ"
        }
    }
}
