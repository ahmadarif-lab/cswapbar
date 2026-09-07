import AppKit
import SwiftUI

enum Theme {
    /// Anthropic "clay" accent.
    static let accent = Color(red: 0.851, green: 0.467, blue: 0.341)

    static let low = Color(red: 0.35, green: 0.69, blue: 0.45)
    static let medium = Color(red: 0.90, green: 0.66, blue: 0.20)
    static let high = Color(red: 0.85, green: 0.32, blue: 0.30)

    static func color(for level: UsageLevel) -> Color {
        switch level {
        case .low: return low
        case .medium: return medium
        case .high: return high
        }
    }

    static func nsColor(for level: UsageLevel) -> NSColor {
        NSColor(color(for: level))
    }

    static let cardBackground = LinearGradient(
        colors: [accent.opacity(0.16), Color.purple.opacity(0.10)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let panelWidth: CGFloat = 340
    /// panelWidth minus the card + row horizontal insets the usage bars sit inside.
    static let barWidth: CGFloat = panelWidth - 36
}

extension View {
    func rowHoverBackground(_ isHovering: Bool) -> some View {
        self.background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering ? Color.primary.opacity(0.08) : Color.clear)
        )
    }
}
