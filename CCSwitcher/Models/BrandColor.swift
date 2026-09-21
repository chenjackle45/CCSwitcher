import AppKit
import Foundation
import SwiftUI

extension Color {
    /// CCSwitcher brand color.
    // static let brand = Color(red: 0x7C / 255.0, green: 0x3A / 255.0, blue: 0xED / 255.0) // #7C3AED
    static let brand = Color(rgb: UsagePalette.terracotta) // #D97757

    /// Creates a color that automatically adapts between light and dark appearance.
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        }))
    }

    init?(hexRGB: String) {
        let trimmed = hexRGB.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }

    var hexRGB: String? {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }

        func channel(_ component: CGFloat) -> Int {
            min(max(Int(round(component * 255)), 0), 255)
        }

        return String(
            format: "#%02X%02X%02X",
            channel(rgb.redComponent),
            channel(rgb.greenComponent),
            channel(rgb.blueComponent)
        )
    }

    // MARK: - Card

    /// Standard card fill.
    static let cardFill = adaptive(light: warmWhite.opacity(0.28), dark: warmWhite.opacity(0.07))
    /// Emphasized card fill (e.g. active account row).
    static let cardFillStrong = adaptive(light: warmWhite.opacity(0.40), dark: warmWhite.opacity(0.12))
    /// Standard card border.
    static let cardBorder = adaptive(light: warmWhite.opacity(0.50), dark: warmWhite.opacity(0.10))

    // MARK: - Tab Bar

    /// Tab bar background fill.
    static let tabFill = adaptive(light: warmGray.opacity(0.14), dark: warmGray.opacity(0.24))
    /// Tab bar border.
    static let tabBorder = adaptive(light: warmWhite.opacity(0.45), dark: warmWhite.opacity(0.10))

    // MARK: - Text

    /// Primary text color for cards and tab selected state.
    static let textPrimary = adaptive(light: Color.primary, dark: Color(rgb: 0xF7F3EE))
    /// Secondary text color for card labels and tab unselected state.
    static let textSecondary = adaptive(light: Color.secondary, dark: Color(rgb: 0xF0E8DE).opacity(0.62))
    /// Terracotta text on a terracotta-tinted background.
    static let brandText = UsagePalette.brandText.adaptive

    // MARK: - Subtle Backgrounds

    /// Subtle brand tint for banners and badges.
    static let subtleBrand = adaptive(light: brand.opacity(0.12), dark: brand.opacity(0.28))
    /// Progress bar track.
    static let progressTrack = adaptive(light: warmGray.opacity(0.18), dark: warmWhite.opacity(0.12))

    // MARK: - Usage Levels

    static let usageNormal = UsagePalette.normal.adaptive
    static let usageWarning = UsagePalette.warning.adaptive
    static let usageCritical = UsagePalette.critical.adaptive

    private static let warmWhite = Color(rgb: 0xFFF5EB)
    private static let warmGray = Color(rgb: 0x8A7F76)
}

extension UsagePalette.Tone {
    /// The tone as a color that follows the app's light / dark appearance.
    var adaptive: Color {
        Color.adaptive(light: Color(rgb: light), dark: Color(rgb: dark))
    }
}

extension ShapeStyle where Self == Color {
    static var brand: Color { .brand }
    static var cardFill: Color { .cardFill }
    static var cardFillStrong: Color { .cardFillStrong }
    static var cardBorder: Color { .cardBorder }
    static var tabFill: Color { .tabFill }
    static var tabBorder: Color { .tabBorder }
    static var textPrimary: Color { .textPrimary }
    static var textSecondary: Color { .textSecondary }
    static var subtleBrand: Color { .subtleBrand }
    static var progressTrack: Color { .progressTrack }
    static var brandText: Color { .brandText }
    static var usageNormal: Color { .usageNormal }
    static var usageWarning: Color { .usageWarning }
    static var usageCritical: Color { .usageCritical }
}
