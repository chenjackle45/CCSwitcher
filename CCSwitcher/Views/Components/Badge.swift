import SwiftUI

/// Reusable capsule badge for status indicators (subscription type, active state, etc.).
struct Badge: View {
    enum Style {
        /// Solid fill, white text — for the one badge that must be spotted at a
        /// glance (which account is in use).
        case solid
        /// Tinted background, colored text.
        case soft
        /// Hairline outline, colored text (plan name).
        case outline
    }

    let text: String
    let color: Color
    var style: Style = .soft

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(style == .solid ? .white : color)
            .padding(.horizontal, AppStyle.badgeHPadding)
            .padding(.vertical, AppStyle.badgeVPadding)
            .background {
                switch style {
                case .solid:
                    Capsule().fill(color)
                case .soft:
                    Capsule().fill(color.opacity(0.18))
                case .outline:
                    Capsule().strokeBorder(color.opacity(0.6), lineWidth: 1)
                }
            }
    }
}
