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
        let saved = UserDefaults.standard.string(forKey: "appLanguage") ?? "en"
        self.currentLanguage = AppLanguage(rawValue: saved) ?? .en
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
    var paywall: PaywallStrings { PaywallStrings(language: language) }
    var quickAdd: QuickAddStrings { QuickAddStrings(language: language) }
    var onboarding: OnboardingStrings { OnboardingStrings(language: language) }
    var persistence: PersistenceStrings { PersistenceStrings(language: language) }

    // Alarm / Notification
    var alarm: AlarmStrings { AlarmStrings(language: language) }
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

    // 알림 콘텐츠
    var notifSubtitleStrong: String { t("⚠️ Needs your attention now", "⚠️ 긴급 확인이 필요합니다", "⚠️ 今すぐ確認が必要です") }
    var notifSubtitleWeak: String { t("One small step today", "오늘의 한 걸음", "今日の一歩") }
    var notifSubtitleFollowUp: String { t("Still waiting on this", "아직 완료되지 않았어요", "まだ完了していません") }

    // 알림 액션
    var completeAction: String { t("Done", "완료", "完了") }
    var snoozeAction: String { t("Snooze 5 min", "5분 뒤 다시", "5分後に再通知") }

    // AlarmKit 스누즈 카운트다운 타이틀
    var countdownTitle: String { t("Snoozed", "다시 알림", "再通知") }

    // 풀스크린 오버레이 (Pro 폴백 UI)
    var overlaySubtitle: String { t("Check it off right now", "지금 바로 확인하고 완료하세요", "今すぐ確認して完了しましょう") }
    var overlayConfirm: String { t("Done", "확인", "確認") }
    var overlayHint: String { t("Tap to dismiss", "탭하여 알람 끄기", "タップしてアラームを消す") }
    func overlayA11yLabel(_ name: String) -> String {
        t("Alarm: \(name). Check it off right now",
          "알람: \(name). 지금 바로 확인하고 완료하세요",
          "アラーム: \(name)。今すぐ確認して完了しましょう")
    }
    func overlayA11yHint(_ name: String) -> String {
        t("Double tap to dismiss the alarm for \(name)",
          "탭하여 \(name) 알람을 끕니다",
          "タップして\(name)のアラームを消します")
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
    var routineReminders: String { t("Routine Reminders", "루틴 알림", "ルーティン通知") }
    var appointmentReminders: String { t("Appointment Reminders", "일정 알림", "予定通知") }
    var remindBefore: String { t("Remind Before", "사전 알림", "事前通知") }
    var sound: String { t("Sound", "사운드", "サウンド") }
    var appearance: String { t("Appearance", "외관", "外観") }
    var theme: String { t("Theme", "테마", "テーマ") }
    var haptic: String { t("Haptic Feedback", "햅틱 피드백", "触覚フィードバック") }
    var dataManagement: String { t("Data Management", "데이터 관리", "データ管理") }
    var clearCompleted: String { t("Clear Completed Tasks", "완료된 태스크 삭제", "完了タスクを削除") }
    var clearAll: String { t("Clear All Data", "전체 데이터 삭제", "全데이터 삭제") }
    var routineNotifTitle: String { t("🔔 Routine Reminder", "🔔 루틴 알림", "🔔 ルーティン通知") }
    var appointmentNotifTitle: String { t("Appointment Reminder", "일정 알림", "予定通知") }
    var about: String { t("About", "앱 정보", "アプリ情報") }
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
    func clearCompletedPreview(_ count: Int) -> String {
        t(
            "Target: \(count) completed task(s), all types and dates. Delete permanently?",
            "대상: 완료된 태스크 \(count)개, 모든 유형·날짜. 영구 삭제할까요?",
            "対象: 完了タスク\(count)件、全種類・全日付。完全に削除しますか？"
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
    var errorPermission: String { t("Microphone permission needed", "마이크 권한이 필요합니다", "마이크의 허가가 필요합니다") }
    var tryAgain: String { t("Try Again", "다시 시도", "再試行") }
    var confirmTitle: String { t("Review & Confirm", "확인 및 검토", "確認と検討") }
    var confirmUpdate: String { t("Edit", "수정", "編集") }
    
    var actionClearAll: String { t("Clear All Tasks", "모든 일정 지우기", "すべてのタスクをクリア") }
    func actionClearDate(_ date: String) -> String { t("Clear tasks for \(date)", "\(date) 일정 일괄 지우기", "\(date)のタスクを一括削除") }
    func actionPostpone(from: String, to: String) -> String { t("Postpone from \(from) to \(to)", "\(from) 일정을 \(to)로 미루기", "\(from)の予定を\(to)に延期") }
    func actionComplete(_ name: String) -> String { t("Mark \"\(name)\" as complete", "\"\(name)\" 완료 처리", "\"\(name)\"を完了にする") }
    func actionUnknown(_ cmd: String) -> String { t("Unknown command (\(cmd))", "알 수 없는 명령 (\(cmd))", "不明なコマンド (\(cmd))") }

    var guideTitle: String { t("Try saying...", "이렇게 말해보세요...", "こう言ってみてください...") }

    var exampleAdd: String { t("\"Take medicine at 9 AM\"", "\"오전 9시에 약 먹기\"", "\"午前9時に薬を飲む\"") }
    var exampleAppointment: String { t("\"Meeting tomorrow at 3 PM\"", "\"내일 오후 3시에 회의\"", "\"明日午後3時に会議\"") }
    var exampleDelete: String { t("\"Delete exercise\"", "\"운동 삭제\"", "\"運動を削除\"") }

    var confirmAdd: String { t("Add to", "에 추가", "に追加") }
    var confirmDelete: String { t("Delete", "삭제", "削除") }
    var confirmRoutine: String { t("Routine", "루틴", "ルーティン") }
    var confirmAppointment: String { t("Planner", "플래너", "プランナー") }
    var confirmTask: String { t("Today's Task", "오늘 할 일", "今日のタスク") }
    var confirmToday: String { t("Today", "오늘 할 일", "今日") }
    var confirmButton: String { t("Confirm", "확인", "確認") }
    var confirmCancel: String { t("Cancel", "취소", "キャンセル") }
    var confirmSending: String { t("Sending...", "전송 중...", "送信中...") }

    var editTaskTitle: String { t("Edit Task", "일정 수정", "タスク編集") }
    var fieldName: String { t("Task Name", "내용", "内容") }
    var fieldTime: String { t("Time", "시간", "時間") }
    var fieldDate: String { t("Date", "날짜", "日付") }
    var fieldCategory: String { t("Category", "카테고리", "カテゴリー") }
    var save: String { t("Save", "저장", "保存") }
    var cancel: String { t("Cancel", "취소", "キャンセル") }

    var preparingDraft: String { t("Preparing draft...", "초안 준비 중...", "下書きを準備中...") }
    var silenceCountdown: String { t("Draft in", "초안까지", "下書きまで") }
    var micModeTap: String { t("Tap to Toggle", "탭하여 전환", "탭하여 전환") }
    var micModeHold: String { t("Hold to Talk", "길게 눌러 말하기", "押し続けて話す") }
    var micModeTitle: String { t("Mic Mode", "마이크 모드", "마이크 모드") }
    var confirmBeforeSave: String { t("Confirm Before Save", "저장 전 확인", "保存前に確認") }

    var undoButton: String { t("Undo", "되돌리기", "元に戻す") }
    func undoAdded(_ count: Int) -> String { t("\(count) task(s) added", "\(count)개 추가됨", "\(count)件追加") }
    func undoDeleted(_ count: Int) -> String { t("\(count) task(s) deleted", "\(count)개 삭제됨", "\(count)件削除") }
    func undoDeletedSingle(_ name: String) -> String { t("\"\(name)\" deleted", "\"\(name)\" 삭제됨", "\"\(name)\"를 삭제") }
    var undoCompleted: String { t("Marked as done", "완료 처리됨", "完了にしました") }
    var undoUncompleted: String { t("Marked as not done", "미완료 처리됨", "未完了にしました") }
    func undoUpdated(_ name: String) -> String { t("\"\(name)\" updated", "\"\(name)\" 수정됨", "「\(name)」を更新") }
    func undoBatch(_ count: Int) -> String { t("\(count) change(s) saved", "\(count)개 변경사항 저장됨", "\(count)件の変更を保存") }
    func affectedCount(_ count: Int) -> String { t("Affects \(count) task(s)", "대상 \(count)개", "対象\(count)件") }
    var reviewUpdatedPreview: String { t("The target changed. Review the updated preview and confirm again", "대상이 변경됐어요. 최신 미리보기를 확인하고 다시 승인해주세요", "対象が変更されました。最新のプレビューを確認してもう一度承認してください") }
    var partialSaveResult: String { t("Saved successful items. Review the items still shown", "성공한 항목은 저장했어요. 남은 항목을 확인해주세요", "成功した項目を保存しました。残りの項目を確認してください") }
    var noMatchingTarget: String { t("No matching task was found", "일치하는 대상을 찾지 못했어요", "一致する対象が見つかりませんでした") }
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
    var existingDraftProtected: String {
        t(
            "Finish or clear the current draft before recording again.",
            "현재 초안을 완료하거나 지운 뒤 다시 녹음해주세요.",
            "現在の下書きを完了または削除してから、もう一度録音してください。"
        )
    }

    var confirmRemoveItem: String { t("Remove", "제거", "削除") }

    var a11yStartRecording: String { t("Start recording", "녹음 시작", "録音開始") }
    var a11yStopRecording: String { t("Stop recording", "녹음 중지", "録音停止") }
    var a11yTapHint: String { t("Tap to start or stop voice input", "탭하여 음성 입력을 시작하거나 중지합니다", "탭하여 음성 입력을 시작하거나 중지합니다") }
    var a11yHoldHint: String {
        t(
            "Press and hold to record, then release to create an editable draft",
            "길게 눌러 녹음하고, 떼면 편집 가능한 초안이 만들어집니다",
            "長押しで録音し、離すと編集可能な下書きになります"
        )
    }
    var a11yTabBar: String { t("Tab navigation", "탭 내비게이션", "탭 내비게이션") }
    var a11yUndo: String { t("Undo last action", "마지막 작업 되돌리기", "最後の操作を元に戻す") }

    var errorMissingTime: String { t("Please set the time for the routine.", "루틴 시간을 설정해주세요.", "ルーティンの時間を設定してください。") }
    var errorMissingDate: String { t("Please set the date for the planner.", "플래너 날짜를 설정해주세요.", "プランナーの日付を設定してください。") }
    var errorMissingAppointmentTime: String { t("Please set the time for the planner.", "플래너 시간을 설정해주세요.", "プランナーの時間を設定してください。") }

    var urgencyStrong: String { t("Strong Alert", "기습 알림", "強い通知") }
    var urgencyWeak: String { t("Gentle Alert", "잔잔 알림", "優しい通知") }
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
    var tosSuffix: String { t(".", "에 동의합니다.", "에 동의합니다.") }
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
    var backOnline: String { t("Back online ✓", "온라인 복구 ✓", "온라인 복구 ✓") }
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

    var page1Title: String { t("Just say it", "말하면 끝", "話すだけ") }
    var page1Body: String { t("One mic for every routine, task, and plan.", "마이크 하나로 루틴, 할 일, 일정까지 전부.", "マイクひとつでルーティンも予定もすべて。") }
    var page3Title: String { t("You're all set", "준비 끝", "準備完了") }
    var page3Body: String { t("Start with your first word.", "첫 마디로 시작해보세요.", "最初のひと言から始めましょう。") }
    var start: String { t("Start", "시작하기", "はじめる") }
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
    var subtitle: String { t("Unlimited AI voice input\nand all premium features.", "AI 음성 입력 무제한\n그리고 모든 프리미엄 기능.", "AI音声入力を無制限に\nすべてのプレミアム機能を。") }
    var purchaseErrorTitle: String { t("Purchase Error", "구매 오류", "購入エラー") }
    var ok: String { t("OK", "확인", "OK") }
    var choosePlan: String { t("CHOOSE YOUR PLAN", "플랜 선택", "プランを選択") }
    var planMonthly: String { t("Monthly", "월간", "月額") }
    var planYearly: String { t("Yearly", "연간", "年額") }
    var billedMonthly: String { t("Billed monthly", "매월 청구", "毎月請求") }
    func billedYearly(monthlyEquivalent: String) -> String {
        t(
            "Billed annually · \(monthlyEquivalent)/mo",
            "연 1회 청구 · 월 \(monthlyEquivalent)",
            "年1回請求 · 月\(monthlyEquivalent)"
        )
    }
    var bestValue: String { t("SAVE 40%", "40% 절약", "40%お得") }
    var subscribe: String { t("Subscribe", "구독하기", "登録する") }
    var startSubscription: String { t("Start Pro", "Pro 시작하기", "Pro を開始") }
    var restore: String { t("Restore Purchases", "구매 복원", "購入を復元") }
    var loadingPlans: String { t("Loading plans...", "플랜 불러오는 중...", "プランを読み込み中...") }
    var loadPlansFailed: String { t("Failed to load plans.", "플랜을 불러오지 못했어요.", "プランの読み込みに失敗しました。") }
    var retry: String { t("Retry", "다시 시도", "再試行") }
    var legalNote: String { t(
        "Subscription renews automatically. Cancel anytime in Settings.",
        "구독은 자동으로 갱신됩니다. 언제든지 설정에서 취소할 수 있습니다.",
        "サブスクリプションは自動的に更新されます。設定からいつでも解約できます。"
    ) }

    var featureVoiceTitle: String { t("Unlimited voice & AI", "무제한 음성 & AI", "無制限の音声 & AI") }
    var featureVoiceDesc: String { t("Free users get 3 AI inputs per day. Pro removes the limit entirely.", "무료는 하루 3회, Pro는 제한 없이 음성·텍스트 AI를 사용할 수 있어요.", "無料は1日3回、Proなら回数制限なしで音声・テキストAIを使えます。") }
    var featureAITitle: String { t("Smart task sorting", "AI 자동 분류", "AIが自動で分類") }
    var featureAIDesc: String { t("AI tells apart routines, tasks, and appointments automatically.", "루틴인지, 할 일인지, 일정인지 AI가 알아서 구분해요.", "ルーティンか、タスクか、予定か、AIが自動で判断します。") }
    var featureAlarmsTitle: String { t("Full-screen alarms", "전체 화면 알람", "フルスクリーンアラーム") }
    var featureAlarmsDesc: String { t("Pro-only full-screen alarms you can't miss.", "절대 놓칠 수 없는 풀스크린 알람 — Pro 전용.", "絶対に見逃せないフルスクリーンアラーム — Pro限定。") }
    var featureWidgetsTitle: String { t("Home screen widgets", "홈 화면 위젯", "ホーム画面ウィジェット") }
    var featureWidgetsDesc: String { t("Pro-only widgets for your Home & Lock Screen.", "홈·잠금 화면 위젯 — Pro 전용.", "ホーム・ロック画面ウィジェット — Pro限定。") }
    var featureSyncTitle: String { t("Cloud backup", "클라우드 백업", "クラウドバックアップ") }
    var featureSyncDesc: String { t("Your data stays safe across devices. (Coming soon)", "기기를 바꿔도 데이터가 안전하게 유지돼요. (출시 예정)", "機種変更してもデータは安全に保管されます。(近日公開)") }

    var subscriptionSection: String { t("Subscription", "구독", "サブスクリプション") }
    var premiumActive: String { t("Pro · Active", "Pro · 활성", "Pro · 有効") }
    var premiumInactive: String { t("Free Plan", "무료 플랜", "無料プラン") }
    var upgradeToPro: String { t("Upgrade to Pro", "Pro로 업그레이드", "Proにアップグレード") }
    var manageSubscription: String { t("Manage Subscription", "구독 관리", "サブスクリプション管理") }
}
