import Foundation
import SwiftUI

// MARK: - Localization System

enum AppLanguage: String, CaseIterable {
    case en, ko, ja

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "en") ?? .en
    }
}

/// 글로벌 접근: L.tabRoutine, L.settings.logOut 등
var L: Strings { Strings() }

private func t(_ en: String, _ ko: String, _ ja: String) -> String {
    switch AppLanguage.current {
    case .en: return en
    case .ko: return ko
    case .ja: return ja
    }
}

struct Strings {
    // Tab Bar
    var tabRoutine: String { t("Routine", "루틴", "ルーティン") }
    var tabVoice: String { t("Voice", "음성", "音声") }
    var tabPlanner: String { t("Planner", "플래너", "プランナー") }

    // Voice Tab
    var voicePlaceholder: String { t("What should I remember for you?", "무엇을 기억해 드릴까요?", "何を覚えておきましょうか？") }
    var voiceListening: String { t("Listening...", "듣고 있어요...", "聞いています...") }
    var voiceAnalyzing: String { t("Analyzing...", "분석 중...", "分析中...") }
    var voice: VoiceStrings { VoiceStrings() }

    // Routine Tab
    var routineTitle: String { t("My Routines", "나의 루틴", "マイルーティン") }
    var routineDailySection: String { t("Daily Routines", "매일 루틴", "デイリールーティン") }
    var routineTodaySection: String { t("Today's Tasks", "오늘 할 일", "今日のタスク") }
    var routineEmptyRoutine: String { t("Tap to add your first routine", "탭하여 첫 루틴을 추가하세요", "タップしてルーティンを追加") }
    var routineEmptyTask: String { t("Tap to add today's task", "탭하여 오늘 할 일을 추가하세요", "タップして今日のタスクを追加") }

    // Planner Tab
    var plannerTitle: String { t("My Planner", "나의 플래너", "マイプランナー") }
    var plannerEmpty: String { t("Tap to add a plan", "탭하여 일정을 추가하세요", "タップして予定を追加") }

    // Offline
    var offlineText: String { t("Offline — voice paused", "오프라인 — 음성 중단", "オフライン — 音声停止") }

    // Settings
    var settings: SettingsStrings { SettingsStrings() }

    // Login
    var login: LoginStrings { LoginStrings() }

    // Network
    var network: NetworkStrings { NetworkStrings() }
}

struct SettingsStrings {
    var title: String { t("Settings", "설정", "設定") }
    var account: String { t("Account", "계정", "アカウント") }
    var logOut: String { t("Log Out", "로그아웃", "ログアウト") }
    var deleteAccount: String { t("Delete Account", "계정 삭제", "アカウント削除") }
    var language: String { t("Language", "언어", "言語") }
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
    var clearAll: String { t("Clear All Data", "전체 데이터 삭제", "全データ削除") }
    var routineNotifTitle: String { t("🔔 Routine Reminder", "🔔 루틴 알림", "🔔 ルーティン通知") }
    var appointmentNotifTitle: String { t("📅 Appointment Reminder", "📅 일정 알림", "📅 予定通知") }
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
    var system: String { t("System", "시스템", "システム") }
    var light: String { t("Light", "라이트", "ライト") }
    var dark: String { t("Dark", "다크", "ダーク") }
    var done: String { t("Done", "완료", "完了") }
    var cancel: String { t("Cancel", "취소", "キャンセル") }
    var delete: String { t("Delete", "삭제", "削除") }
}

struct VoiceStrings {
    // Error messages
    var errorNotHeard: String { t("Couldn't hear you. Try again?", "잘 못 들었어요. 다시 말해주세요", "聞き取れませんでした。もう一度お願いします") }
    var errorRecognitionFailed: String { t("Speech recognition failed. Try again", "음성 인식에 실패했어요. 다시 시도해주세요", "音声認識に失敗しました。再試行してください") }
    var errorNetwork: String { t("No connection. Try again later", "연결이 없어요. 나중에 다시 시도해주세요", "接続がありません。後で再試行してください") }
    var errorApi: String { t("Something went wrong. Try again", "문제가 생겼어요. 다시 시도해주세요", "問題が発生しました。再試行してください") }
    var errorPermission: String { t("Microphone permission needed", "마이크 권한이 필요합니다", "マイクの許可が必要です") }
    var tryAgain: String { t("Try Again", "다시 시도", "再試行") }

    // Voice guide / onboarding hints
    var guideTitle: String { t("Try saying...", "이렇게 말해보세요...", "こう言ってみてください...") }
    var guideHint: String { t("Long press mic for examples", "마이크를 길게 눌러 예시를 확인", "マイクを長押しで例を表示") }

    // Example commands
    var exampleAdd: String { t("\"Take medicine at 9 AM\"", "\"오전 9시에 약 먹기\"", "\"午前9時に薬を飲む\"") }
    var exampleAppointment: String { t("\"Meeting tomorrow at 3 PM\"", "\"내일 오후 3시에 회의\"", "\"明日午後3時に会議\"") }
    var exampleDelete: String { t("\"Delete exercise\"", "\"운동 삭제\"", "\"運動を削除\"") }

    // Confirmation card
    var confirmAdd: String { t("Add to", "에 추가", "に追加") }
    var confirmDelete: String { t("Delete", "삭제", "削除") }
    var confirmRoutine: String { t("Routine", "루틴", "ルーティン") }
    var confirmAppointment: String { t("Planner", "플래너", "プランナー") }
    var confirmButton: String { t("Confirm", "확인", "確認") }
    var confirmCancel: String { t("Cancel", "취소", "キャンセル") }
    var confirmSending: String { t("Sending...", "전송 중...", "送信中...") }

    // Silence countdown
    var silenceCountdown: String { t("Sending in", "전송까지", "送信まで") }

    // Mic mode
    var micModeTap: String { t("Tap to Toggle", "탭하여 전환", "タップで切替") }
    var micModeHold: String { t("Hold to Talk", "길게 눌러 말하기", "押し続けて話す") }
    var micModeTitle: String { t("Mic Mode", "마이크 모드", "マイクモード") }
    var confirmBeforeSave: String { t("Confirm Before Save", "저장 전 확인", "保存前に確認") }

    // Undo
    var undoButton: String { t("Undo", "되돌리기", "元に戻す") }
    func undoAdded(_ count: Int) -> String { t("\(count) task(s) added", "\(count)개 추가됨", "\(count)件追加") }
    func undoDeleted(_ count: Int) -> String { t("\(count) task(s) deleted", "\(count)개 삭제됨", "\(count)件削除") }
    func undoDeletedSingle(_ name: String) -> String { t("\"\(name)\" deleted", "\"\(name)\" 삭제됨", "\"\(name)\"を削除") }
    var undoCompleted: String { t("Marked as done", "완료 처리됨", "完了にしました") }
    var undoUncompleted: String { t("Marked as not done", "미완료 처리됨", "未完了にしました") }

    // Text input
    var textInputPlaceholder: String { t("Type a task...", "할 일을 입력...", "タスクを入力...") }
    var textInputSend: String { t("Send", "전송", "送信") }

    // Confirmation card - remove single item
    var confirmRemoveItem: String { t("Remove", "제거", "削除") }

    // Accessibility
    var a11yStartRecording: String { t("Start recording", "녹음 시작", "録音開始") }
    var a11yStopRecording: String { t("Stop recording", "녹음 중지", "録音停止") }
    var a11yTapHint: String { t("Tap to start or stop voice input", "탭하여 음성 입력을 시작하거나 중지합니다", "タップして音声入力の開始・停止") }
    var a11yHoldHint: String { t("Press and hold to record, release to send", "길게 눌러 녹음하고, 떼면 전송됩니다", "長押しで録音、離すと送信") }
    var a11yTabBar: String { t("Tab navigation", "탭 내비게이션", "タブナビゲーション") }
    var a11yUndo: String { t("Undo last action", "마지막 작업 되돌리기", "最後の操作を元に戻す") }
}

// MARK: - Login Strings
struct LoginStrings {
    var subtitle: String { t("Your AI thoughts companion.", "당신의 AI 생각 도우미.", "あなたのAI思考パートナー。") }
    var tosPrefix: String { t("By signing in, you agree to our ", "로그인하면 ", "サインインすると") }
    var tosLink: String { t("Terms of Service", "이용약관", "利用規約") }
    var tosSuffix: String { t(".", "에 동의합니다.", "に同意したことになります。") }
}

// MARK: - Network Strings
struct NetworkStrings {
    var backOnline: String { t("Back online ✓", "온라인 복구 ✓", "オンライン復帰 ✓") }
}
