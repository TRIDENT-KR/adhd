import SwiftUI

// MARK: - Design System Tokens
struct DesignSystem {
    struct Colors {
        // Adaptive colors: light/dark mode 자동 전환
        static let background = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(r: 0x1A, g: 0x1A, b: 0x1A)
                : UIColor(r: 0xF9, g: 0xF9, b: 0xF7)
        })

        static let primary = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(r: 0xFF, g: 0xB5, b: 0x9B)
                : UIColor(r: 0x93, g: 0x4A, b: 0x2E)
        })

        static let primaryContainer = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(r: 0x7C, g: 0x3F, b: 0x24)
                : UIColor(r: 0xD2, g: 0x7C, b: 0x5C)
        })

        static let primaryFixedDim = Color(hex: "#FFB59B")

        static let onSurfaceVariant = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(r: 0xCF, g: 0xC0, b: 0xB8)
                : UIColor(r: 0x54, g: 0x43, b: 0x3D)
        })

        static let surfaceContainerLow = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(r: 0x25, g: 0x25, b: 0x25)
                : UIColor(r: 0xF4, g: 0xF4, b: 0xF2)
        })

        static let tertiary = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(r: 0x4F, g: 0xDB, b: 0xD1)
                : UIColor(r: 0x00, g: 0x6A, b: 0x63)
        })
    }

    struct Gradients {
        static let primaryCTA = LinearGradient(
            colors: [Colors.primary, Colors.primaryContainer],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    struct Typography {
        static let displayLg = Font.system(size: 34, weight: .semibold, design: .default)
        static let titleSm   = Font.system(size: 20, weight: .medium,   design: .default)
        static let bodyMd    = Font.system(size: 16, weight: .regular,  design: .default)
        static let labelSm   = Font.system(size: 12, weight: .medium,   design: .default)
    }

    // MARK: - Strings
    struct Strings {
        static var offlineAlertText: String { L.offlineText }
    }
}

// MARK: - Tab Selection
enum TabSelection {
    case routine, voice, planner
}

// MARK: - Squishy Button Style
struct SquishyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .animation(.easeOut(duration: 0.2), value: configuration.isPressed)
    }
}

// MARK: - Color Extension for Hex
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red:     Double(r) / 255,
            green:   Double(g) / 255,
            blue:    Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Locale Short Label
extension String {
    /// "en-US" → "EN", "ko-KR" → "KO", "ja-JP" → "JA"
    var localeShortLabel: String {
        String(self.prefix(2)).uppercased()
    }
}

// MARK: - UIColor convenience for RGB bytes
extension UIColor {
    convenience init(r: UInt8, g: UInt8, b: UInt8) {
        self.init(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}
