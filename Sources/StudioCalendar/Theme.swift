import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

/// Studio look: white or black, one huge number, hard edges, flat colour blocks.
struct Theme {
    let dark: Bool

    var bg: Color { dark ? Color(hex: 0x0B0B0B) : .white }
    var fg: Color { dark ? Color(hex: 0xF2F2F2) : Color(hex: 0x0A0A0A) }
    var muted: Color { dark ? Color(hex: 0x7A7A7A) : Color(hex: 0x8C8C8C) }
    var hair: Color { fg.opacity(0.08) }
    var chipBg: Color { dark ? Color(hex: 0x1C1C1C) : Color(hex: 0xF0F0F0) }
    var card: Color { dark ? Color(hex: 0x141414) : .white }
    var onFill: Color { Color(hex: 0x0A0A0A) }

    func fill(_ c: Category) -> Color {
        switch c {
        case .meeting: return Color(hex: 0xFF8FB8)
        case .uni: return Color(hex: 0xB9A6FF)
        case .work: return Color(hex: 0x8EE3A8)
        case .focus: return Color(hex: 0x8CC8FF)
        }
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme(dark: false)
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// Small uppercase label in monospace, used for section titles.
struct Label11: View {
    @Environment(\.theme) var th
    let text: String
    var color: Color?
    var body: some View {
        Text(text.uppercased())
            .font(Theme.mono(11))
            .tracking(1.1)
            .foregroundStyle(color ?? th.muted)
    }
}
