import SwiftUI

// MARK: - Widget Design System
/// 메인 앱의 DesignSystem과 동일한 색상·타이포그래피 토큰 (위젯 전용 복제본)
struct WDS {
    // MARK: Colors
    struct Colors {
        static let background = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0x1A/255.0, green: 0x1A/255.0, blue: 0x1A/255.0, alpha: 1)
                : UIColor(red: 0xF9/255.0, green: 0xF9/255.0, blue: 0xF7/255.0, alpha: 1)
        })

        static let primary = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0xFF/255.0, green: 0xB5/255.0, blue: 0x9B/255.0, alpha: 1)
                : UIColor(red: 0x93/255.0, green: 0x4A/255.0, blue: 0x2E/255.0, alpha: 1)
        })

        static let primaryContainer = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0x7C/255.0, green: 0x3F/255.0, blue: 0x24/255.0, alpha: 1)
                : UIColor(red: 0xD2/255.0, green: 0x7C/255.0, blue: 0x5C/255.0, alpha: 1)
        })

        static let onSurfaceVariant = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0xCF/255.0, green: 0xC0/255.0, blue: 0xB8/255.0, alpha: 1)
                : UIColor(red: 0x54/255.0, green: 0x43/255.0, blue: 0x3D/255.0, alpha: 1)
        })

        static let surfaceContainerLow = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0x25/255.0, green: 0x25/255.0, blue: 0x25/255.0, alpha: 1)
                : UIColor(red: 0xF4/255.0, green: 0xF4/255.0, blue: 0xF2/255.0, alpha: 1)
        })

        static let tertiary = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0x4F/255.0, green: 0xDB/255.0, blue: 0xD1/255.0, alpha: 1)
                : UIColor(red: 0x00/255.0, green: 0x6A/255.0, blue: 0x63/255.0, alpha: 1)
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
    struct Typography {
        static let titleSm   = Font.system(size: 15, weight: .semibold)
        static let bodyMd    = Font.system(size: 13, weight: .medium)
        static let labelSm   = Font.system(size: 11, weight: .medium)
        static let caption   = Font.system(size: 10, weight: .regular)
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
    static var noTasks: String {
        switch currentLang {
        case "ko": return "등록된 할 일이 없어요"
        case "ja": return "タスクがありません"
        default:   return "No tasks yet"
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

    static var moreTasks: String {
        switch currentLang {
        case "ko": return "더보기"
        case "ja": return "もっと見る"
        default:   return "more"
        }
    }

    static var tasksRemaining: String {
        switch currentLang {
        case "ko": return "남음"
        case "ja": return "残り"
        default:   return "left"
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

    private static var currentLang: String {
        UserDefaults.standard.string(forKey: "appLanguage") ?? "en"
    }
}
