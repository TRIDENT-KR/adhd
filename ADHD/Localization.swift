import Foundation
import Combine
import SwiftUI

// MARK: - Localization Manager
class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()
    
    @Published var currentLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(currentLanguage.rawValue, forKey: "appLanguage")
        }
    }
    
    private init() {
        let saved = UserDefaults.standard.string(forKey: "appLanguage") ?? "en"
        self.currentLanguage = AppLanguage(rawValue: saved) ?? .en
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
    var guideHint: String { t("Long press mic for examples", "마이크를 길게 눌러 예시를 확인", "마이크를 길게 눌러서 예를 표시") }

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

    var silenceCountdown: String { t("Sending in", "전송까지", "送信まで") }
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

    var textInputPlaceholder: String { t("Type a task...", "할 일을 입력...", "タスクを入力...") }
    var textInputSend: String { t("Send", "전송", "送信") }

    var confirmRemoveItem: String { t("Remove", "제거", "削除") }

    var a11yStartRecording: String { t("Start recording", "녹음 시작", "録音開始") }
    var a11yStopRecording: String { t("Stop recording", "녹음 중지", "録音停止") }
    var a11yTapHint: String { t("Tap to start or stop voice input", "탭하여 음성 입력을 시작하거나 중지합니다", "탭하여 음성 입력을 시작하거나 중지합니다") }
    var a11yHoldHint: String { t("Press and hold to record, release to send", "길게 눌러 녹음하고, 떼면 전송됩니다", "長押しで録音、離すと送信") }
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
    var choosePlan: String { t("CHOOSE YOUR PLAN", "플랜 선택", "プランを選択") }
    var planMonthly: String { t("Monthly", "월간", "月額") }
    var planYearly: String { t("Yearly", "연간", "年額") }
    var billedMonthly: String { t("Billed monthly", "매월 청구", "毎月請求") }
    var billedYearly: String { t("Billed annually · $3.00/mo", "연 1회 청구 · 월 $3.00", "年1回請求 · 月$3.00") }
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
    var featureAlarmsDesc: String { t("Can't-miss alarms that fill the whole screen.", "화면 가득 뜨는 알람으로 절대 놓치지 않아요.", "画面いっぱいのアラームで絶対に見逃しません。") }
    var featureWidgetsTitle: String { t("Home screen widgets", "홈 화면 위젯", "ホーム画面ウィジェット") }
    var featureWidgetsDesc: String { t("See today's tasks and routines without opening the app.", "앱을 열지 않아도 오늘 할 일과 루틴을 바로 확인하세요.", "アプリを開かなくても今日のタスクとルーティンを確認。") }
    var featureSyncTitle: String { t("Cloud backup", "클라우드 백업", "クラウドバックアップ") }
    var featureSyncDesc: String { t("Your data stays safe across devices. (Coming soon)", "기기를 바꿔도 데이터가 안전하게 유지돼요. (출시 예정)", "機種変更してもデータは安全に保管されます。(近日公開)") }

    var subscriptionSection: String { t("Subscription", "구독", "サブスクリプション") }
    var premiumActive: String { t("Pro · Active", "Pro · 활성", "Pro · 有効") }
    var premiumInactive: String { t("Free Plan", "무료 플랜", "無料プラン") }
    var upgradeToPro: String { t("Upgrade to Pro", "Pro로 업그레이드", "Proにアップグレード") }
    var manageSubscription: String { t("Manage Subscription", "구독 관리", "サブスクリプション管理") }
}
