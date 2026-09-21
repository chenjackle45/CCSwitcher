import SwiftUI

/// "Claude terracotta" palette shared by the app and the widget.
///
/// Each tone is a light/dark pair of RGB values instead of a dynamic color:
/// the widget resolves it against its `colorScheme` environment, the app wraps
/// it in an adaptive `NSColor` (see `BrandColor.swift`).
enum UsagePalette {
    struct Tone: Sendable {
        let light: UInt32
        let dark: UInt32

        func color(_ scheme: ColorScheme) -> Color {
            Color(rgb: scheme == .dark ? dark : light)
        }
    }

    static let terracotta: UInt32 = 0xD97757

    /// Accent text on a terracotta-tinted background (active badge, active row).
    static let brandText = Tone(light: 0xB4532F, dark: 0xF0A488)

    // Usage levels. Thresholds are unchanged: 60% turns amber, 90% turns red.
    static let normal = Tone(light: 0xC4A484, dark: 0xE9D8C4)
    static let warning = Tone(light: 0xCC8A2E, dark: 0xE3A84F)
    static let critical = Tone(light: 0xD4553A, dark: 0xE5674B)

    static func level(_ utilization: Double) -> Tone {
        if utilization >= 90 { return critical }
        if utilization >= 60 { return warning }
        return normal
    }

    static func model(_ name: String) -> Tone {
        switch name {
        case "Opus": return Tone(light: terracotta, dark: terracotta)
        case "Fable": return normal
        case "Sonnet": return Tone(light: 0xB08968, dark: 0xB08968)
        default: return Tone(light: 0x8A7F76, dark: 0x8A7F76)
        }
    }

    /// Percentage label for a 0–100 utilization. "Remaining" mode shows the
    /// quota left with an explicit suffix so it can't be mistaken for usage.
    static func percentText(_ utilization: Double, showsRemaining: Bool) -> LocalizedStringKey {
        let used = Int(utilization)
        return showsRemaining ? "\(max(0, 100 - used))% left" : "\(used)%"
    }
}

/// UserDefaults key for the "usage numbers: used / remaining" setting.
enum UsageDisplaySetting {
    static let showsRemainingKey = "showsRemainingUsage"
}

extension Color {
    init(rgb: UInt32) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}
