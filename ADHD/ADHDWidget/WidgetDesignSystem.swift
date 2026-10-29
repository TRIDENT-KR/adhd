import SwiftUI
import AppIntents

// MARK: - Widget Design System
/// 메인 앱의 DesignSystem과 동일한 색상·타이포그래피 토큰 (위젯 전용 복제본)
struct WDS {
    // MARK: Colors
    struct Colors {
        // 앱(DesignSystem)과 같은 따뜻한 다크 팔레트
        static let background = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0x1C/255.0, green: 0x1A/255.0, blue: 0x19/255.0, alpha: 1)
                : UIColor(red: 0xF9/255.0, green: 0xF9/255.0, blue: 0xF7/255.0, alpha: 1)
        })

        static let primary = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0xFF/255.0, green: 0xB5/255.0, blue: 0x9B/255.0, alpha: 1)
                : UIColor(red: 0x93/255.0, green: 0x4A/255.0, blue: 0x2E/255.0, alpha: 1)
        })

        static let primaryContainer = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0xF0/255.0, green: 0xA0/255.0, blue: 0x80/255.0, alpha: 1)
                : UIColor(red: 0xD2/255.0, green: 0x7C/255.0, blue: 0x5C/255.0, alpha: 1)
        })

        static let onSurfaceVariant = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0xCF/255.0, green: 0xC0/255.0, blue: 0xB8/255.0, alpha: 1)
                : UIColor(red: 0x54/255.0, green: 0x43/255.0, blue: 0x3D/255.0, alpha: 1)
        })

        /// 시간·개수·완료한 할 일 같은 보조 글자 (앱 onSurfaceMeta와 같은 값).
        /// 배경 위 4.5:1 이상이라, 보조 글자에 onSurfaceVariant.opacity(…) 대신 이 색을 씁니다.
        static let onSurfaceMeta = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0xC2/255.0, green: 0xB5/255.0, blue: 0xAD/255.0, alpha: 1)
                : UIColor(red: 0x6E/255.0, green: 0x5F/255.0, blue: 0x58/255.0, alpha: 1)
        })

        /// 빈 체크 원 테두리 (조작 요소 3:1 이상, 앱 outline과 같은 값)
        static let outline = Color(red: 0x8A/255.0, green: 0x7D/255.0, blue: 0x76/255.0)

        static let surfaceContainerLow = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0x2A/255.0, green: 0x26/255.0, blue: 0x24/255.0, alpha: 1)
                : UIColor(red: 0xF1/255.0, green: 0xEE/255.0, blue: 0xEB/255.0, alpha: 1)
        })

        static let tertiary = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0x6F/255.0, green: 0xD8/255.0, blue: 0xCF/255.0, alpha: 1)
                : UIColor(red: 0x00/255.0, green: 0x6A/255.0, blue: 0x63/255.0, alpha: 1)
        })

        /// tertiary(완료 체크) 위 체크 표시
        static let onTertiary = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0x00/255.0, green: 0x33/255.0, blue: 0x2F/255.0, alpha: 1)
                : UIColor(red: 0xFF/255.0, green: 0xFF/255.0, blue: 0xFF/255.0, alpha: 1)
        })

        static let primaryFixedDim = Color(
            red: 0xFF/255.0, green: 0xB5/255.0, blue: 0x9B/255.0
        )
    }

    // MARK: Gradients
    struct Gradients {
        static let primaryCTA = LinearGradient(
            colors: [Colors.primary, Colors.primaryContainer],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: Typography
    /// 글자 크기 설정을 따르도록 텍스트 스타일을 씁니다. 기본 크기에서 가장 작은 글자도 12pt입니다.
    struct Typography {
        static let headline  = Font.headline                    // 17pt — 위젯의 초점 (다음 할 일 이름, 날짜)
        static let titleSm   = Font.subheadline.weight(.semibold) // 15pt
        static let bodyMd    = Font.subheadline                 // 15pt — 할 일 이름
        static let labelSm   = Font.caption.weight(.semibold)   // 12pt — 섹션 이름
        static let caption   = Font.caption                     // 12pt — 시간·개수
    }

    // MARK: Layout
    /// 글자를 키운 사용자에게는 줄 수를 줄여 아래가 잘리지 않게 합니다.
    static func rowLimit(_ base: Int, for size: DynamicTypeSize) -> Int {
        let scale: Double
        switch size {
        case ...DynamicTypeSize.large: return base
        case .xLarge:                  scale = 0.75   // 3줄 → 2줄, 8줄 → 6줄
        default:                       scale = 0.65   // 3줄 → 2줄, 8줄 → 5줄
        }
        return max(1, Int((Double(base) * scale).rounded()))
    }

    /// 위젯이 감당할 수 있는 가장 큰 글자 크기. 더 크면 한 줄도 들어가지 않습니다.
    static let maxTypeSize = DynamicTypeSize.xxLarge
}

// MARK: - 완료 체크 원
/// 앱 할 일 행의 체크 원(TaskCheckCircle)과 같은 모양: 빈 원은 테두리, 완료는 채운 원 + 체크.
struct WidgetCheckCircle: View {
    let isCompleted: Bool
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            if isCompleted {
                Circle()
                    .fill(WDS.Colors.tertiary)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(WDS.Colors.onTertiary)
            } else {
                Circle()
                    .strokeBorder(WDS.Colors.outline, lineWidth: 2)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 완료 버튼
/// 위젯에서 바로 완료를 바꾸는 버튼. 누르는 영역을 원보다 넓게 잡고,
/// VoiceOver에는 할 일 이름·완료 여부·누르면 일어나는 일을 알려 줍니다.
struct WidgetCompleteButton: View {
    let task: WidgetTaskSnapshot
    var size: CGFloat = 20
    var hitSize: CGFloat = 30

    var body: some View {
        Button(intent: ToggleTaskIntent(taskID: task.id.uuidString)) {
            WidgetCheckCircle(isCompleted: task.isCompleted, size: size)
                .frame(width: hitSize, height: hitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(task.task)
        .accessibilityValue(task.isCompleted ? WidgetL.done : WidgetL.notDone)
        .accessibilityHint(task.isCompleted ? WidgetL.markNotDoneHint : WidgetL.markDoneHint)
    }
}

// MARK: - 할 일 한 줄
/// 완료 버튼 + 이름 + 시간. 시간은 잘리지 않고, 길면 이름이 줄어듭니다.
struct WidgetTaskRow: View {
    let task: WidgetTaskSnapshot
    var hitSize: CGFloat = 30
    /// 루틴·일정이 섞인 목록에서만 종류 아이콘을 보여 줍니다.
    var showsCategory = false

    var body: some View {
        HStack(spacing: 4) {
            WidgetCompleteButton(task: task, hitSize: hitSize)

            Text(task.task)
                .font(WDS.Typography.bodyMd)
                .foregroundStyle(task.isCompleted ? WDS.Colors.onSurfaceMeta : WDS.Colors.onSurfaceVariant)
                // 줄 색은 글자 색을 따릅니다. 동적 색을 따로 넘기면 홈 화면에서 줄이 빠지는 경우가 있었습니다.
                .strikethrough(task.isCompleted)
                .lineLimit(1)
                .accessibilityHidden(true)   // 이름은 완료 버튼이 읽어 줍니다

            Spacer(minLength: 6)

            if showsCategory {
                Image(systemName: task.category == "Routine" ? "arrow.trianglehead.2.counterclockwise" : "calendar")
                    .font(WDS.Typography.caption)
                    .foregroundStyle(WDS.Colors.onSurfaceMeta)
                    .accessibilityHidden(true)
            }

            if let time = task.displayTime {
                Text(time)
                    .font(WDS.Typography.caption)
                    .foregroundStyle(WDS.Colors.onSurfaceMeta)
                    .fixedSize()
            }
        }
        .frame(minHeight: hitSize)
    }
}

// MARK: - Widget Localized Strings
/// 위젯에서 사용하는 최소한의 다국어 문자열
struct WidgetL {
    static var nextTask: String {
        switch currentLang {
        case "ko": return "다음 할 일"
        case "ja": return "次のタスク"
        default:   return "Next Task"
        }
    }
    static var allDone: String {
        switch currentLang {
        case "ko": return "모두 완료!"
        case "ja": return "全て完了!"
        default:   return "All Done!"
        }
    }
    static var routines: String {
        switch currentLang {
        case "ko": return "루틴"
        case "ja": return "ルーティン"
        default:   return "Routines"
        }
    }
    static var appointments: String {
        switch currentLang {
        case "ko": return "일정"
        case "ja": return "予定"
        default:   return "Appointments"
        }
    }
    static var today: String {
        switch currentLang {
        case "ko": return "오늘"
        case "ja": return "今日"
        default:   return "Today"
        }
    }
    /// 오늘 할 일이 없을 때. 다른 날에는 있을 수 있으니 '등록된 할 일이 없다'고 하지 않습니다.
    static var noTasks: String {
        switch currentLang {
        case "ko": return "오늘 할 일이 없어요"
        case "ja": return "今日はタスクなし"
        default:   return "Nothing planned today"
        }
    }
    static var noRoutines: String {
        switch currentLang {
        case "ko": return "오늘 루틴이 없어요"
        case "ja": return "今日のルーティンはありません"
        default:   return "No routines today"
        }
    }
    static var tapToAdd: String {
        switch currentLang {
        case "ko": return "탭해서 추가하기"
        case "ja": return "タップして追加"
        default:   return "Tap to add"
        }
    }

    // MARK: - Enhanced Widget Strings
    static var upNext: String {
        switch currentLang {
        case "ko": return "다음 할 일"
        case "ja": return "次にやること"
        default:   return "Up Next"
        }
    }

    /// 목록에 다 못 보여 준 개수: "+2 more", "외 2개", "ほか2件"
    static func more(_ count: Int) -> String {
        switch currentLang {
        case "ko": return "외 \(count)개"
        case "ja": return "ほか\(count)件"
        default:   return "+\(count) more"
        }
    }

    /// 남은 개수: "3 left", "3개 남음", "残り3件"
    static func remaining(_ count: Int) -> String {
        switch currentLang {
        case "ko": return "\(count)개 남음"
        case "ja": return "残り\(count)件"
        default:   return "\(count) left"
        }
    }

    static var routineProgress: String {
        switch currentLang {
        case "ko": return "루틴 진행률"
        case "ja": return "ルーティン進捗"
        default:   return "Routine Progress"
        }
    }

    static var taskCount: String {
        switch currentLang {
        case "ko": return "남은 할 일"
        case "ja": return "残りタスク"
        default:   return "Tasks Left"
        }
    }

    static var noPendingTasks: String {
        switch currentLang {
        case "ko": return "남은 할 일이 없어요"
        case "ja": return "残りのタスクはありません"
        default:   return "No pending tasks"
        }
    }

    // MARK: - 위젯 갤러리 설명 (한 문장)
    static var nextTaskDescription: String {
        switch currentLang {
        case "ko": return "다음 할 일을 보고 바로 체크해요."
        case "ja": return "次のタスクを見て、すぐにチェックできます。"
        default:   return "See your next task and check it off."
        }
    }

    static var routinesDescription: String {
        switch currentLang {
        case "ko": return "오늘 루틴을 바로 체크해요."
        case "ja": return "今日のルーティンをすぐにチェックできます。"
        default:   return "Check off today's routines."
        }
    }

    static var overviewDescription: String {
        switch currentLang {
        case "ko": return "오늘 루틴과 일정을 한곳에서 봐요."
        case "ja": return "今日のルーティンと予定をまとめて見られます。"
        default:   return "Today's routines and plans in one place."
        }
    }

    static var routineProgressDescription: String {
        switch currentLang {
        case "ko": return "오늘 루틴을 얼마나 했는지 보여 줘요."
        case "ja": return "今日のルーティンの進み具合を表示します。"
        default:   return "See how today's routines are going."
        }
    }

    static var nextTaskLockDescription: String {
        switch currentLang {
        case "ko": return "잠금 화면에서 다음 할 일을 봐요."
        case "ja": return "ロック画面に次のタスクを表示します。"
        default:   return "Your next task on the Lock Screen."
        }
    }

    static var taskCountDescription: String {
        switch currentLang {
        case "ko": return "오늘 남은 할 일 수를 보여 줘요."
        case "ja": return "今日の残りタスク数を表示します。"
        default:   return "How many tasks are left today."
        }
    }

    // MARK: - 완료 버튼 (VoiceOver)
    static var done: String {
        switch currentLang {
        case "ko": return "완료"
        case "ja": return "完了"
        default:   return "Done"
        }
    }

    static var notDone: String {
        switch currentLang {
        case "ko": return "미완료"
        case "ja": return "未完了"
        default:   return "Not done"
        }
    }

    static var markDoneHint: String {
        switch currentLang {
        case "ko": return "완료로 표시해요."
        case "ja": return "完了にします。"
        default:   return "Marks it as done."
        }
    }

    static var markNotDoneHint: String {
        switch currentLang {
        case "ko": return "미완료로 되돌려요."
        case "ja": return "未完了に戻します。"
        default:   return "Marks it as not done."
        }
    }

    // MARK: - Alarm Live Activity Strings
    static var alarmNow: String {
        switch currentLang {
        case "ko": return "할 시간이에요"
        case "ja": return "時間です"
        default:   return "It's time"
        }
    }

    static var alarmSnoozed: String {
        switch currentLang {
        case "ko": return "다시 알림"
        case "ja": return "再通知"
        default:   return "Snoozed"
        }
    }

    static var alarmPaused: String {
        switch currentLang {
        case "ko": return "일시정지"
        case "ja": return "一時停止"
        default:   return "Paused"
        }
    }

    // MARK: - 잠긴 위젯 (이유 한 문장)
    /// "Mora Pro"는 줄바꿈 없는 공백(\u{00A0})으로 묶어 "Mora / Pro"로 갈라지지 않게 합니다.
    static func lockMessage(_ reason: WidgetLockReason) -> String {
        switch reason {
        case .needsPro:
            switch currentLang {
            case "ko": return "위젯은 Mora\u{00A0}Pro에서 쓸 수 있어요."
            case "ja": return "Mora\u{00A0}Proで使えます。"
            default:   return "Widgets come with Mora\u{00A0}Pro."
            }
        case .needsAppOpen:
            switch currentLang {
            case "ko": return "Mora를 한 번 열면 바로 보여요."
            case "ja": return "Moraを一度開くと使えます。"
            default:   return "Open Mora once to show it here."
            }
        }
    }

    static var openApp: String {
        switch currentLang {
        case "ko": return "Mora 열기"
        case "ja": return "Moraを開く"
        default:   return "Open Mora"
        }
    }

    // MARK: - 위젯 갤러리 미리보기용 예시 할 일
    static var sampleMedicine: String {
        switch currentLang {
        case "ko": return "약 먹기"
        case "ja": return "薬を飲む"
        default:   return "Take medicine"
        }
    }

    static var sampleWalk: String {
        switch currentLang {
        case "ko": return "아침 산책"
        case "ja": return "朝の散歩"
        default:   return "Morning walk"
        }
    }

    static var sampleReading: String {
        switch currentLang {
        case "ko": return "20분 책 읽기"
        case "ja": return "20分読書"
        default:   return "Read for 20 minutes"
        }
    }

    static var sampleWindDown: String {
        switch currentLang {
        case "ko": return "잠들 준비"
        case "ja": return "寝る準備"
        default:   return "Wind down"
        }
    }

    static var sampleMeeting: String {
        switch currentLang {
        case "ko": return "팀 회의"
        case "ja": return "チーム会議"
        default:   return "Team meeting"
        }
    }

    static var sampleDentist: String {
        switch currentLang {
        case "ko": return "치과"
        case "ja": return "歯医者"
        default:   return "Dentist"
        }
    }

    static var sampleWeekly: String {
        switch currentLang {
        case "ko": return "매주"
        case "ja": return "毎週"
        default:   return "Weekly"
        }
    }

    /// 날짜·요일을 앱 언어로 쓰기 위한 로케일 (기기 언어가 아니라)
    static var locale: Locale {
        Locale(identifier: ["ko": "ko-KR", "ja": "ja-JP"][currentLang] ?? "en-US")
    }

    // 버그③: 위젯은 별도 프로세스라 standard defaults를 읽으면 항상 영어로 표시됨
    // — 메인 앱이 App Group에 복제한 언어를 읽어야 한다 (LocalizationManager didSet과 한 쌍)
    private static var currentLang: String {
        UserDefaults(suiteName: appGroupID)?.string(forKey: "appLanguage") ?? "en"
    }
}
