import AppKit

/// Draws a provider's menu bar image: its logo, its mini usage bars (5h on
/// top, 7d below), or both side by side -- whichever `MenuBarStyle` asks for.
///
/// Rendered as an NSImage rather than SwiftUI shapes: MenuBarExtra reliably
/// renders only Text/Image in its label -- Capsule/Canvas draw nothing there.
/// Not a template image, since the bars carry their own usage colors; the
/// logo is drawn in `labelColor` instead, resolved against the menu bar's
/// appearance at draw time just like the bars' track color.
enum MenuBarIcon {
    private static let iconSide: CGFloat = 15
    private static let barsWidth: CGFloat = 22
    private static let barHeight: CGFloat = 3
    private static let barGap: CGFloat = 3
    private static let spacing: CGFloat = 4

    /// `topPct`/`bottomPct` are usually a provider's 5-hour/weekly windows,
    /// already condensed to one number per window (see
    /// `[ProviderAccount].menuBarPercentages()`). Returns nil when neither
    /// part is asked for.
    static func make(icon: ProviderIconSource?, bars: (top: Double?, bottom: Double?)?) -> NSImage? {
        guard icon != nil || bars != nil else { return nil }
        let barsHeight = barHeight * 2 + barGap
        let iconWidth = icon == nil ? 0 : iconSide
        let width = iconWidth + (icon != nil && bars != nil ? spacing : 0) + (bars == nil ? 0 : barsWidth)
        let height = icon == nil ? barsHeight : iconSide

        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            if let icon {
                draw(icon, in: NSRect(x: 0, y: 0, width: iconSide, height: iconSide))
            }
            if let bars {
                let x = width - barsWidth
                let top = (height - barsHeight) / 2
                draw(pct: bars.top, x: x, y: top)
                draw(pct: bars.bottom, x: x, y: top + barHeight + barGap)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func draw(_ icon: ProviderIconSource, in rect: NSRect) {
        switch icon {
        case .glyph(let glyph):
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.addPath(glyph.path(in: rect).cgPath)
            context.setFillColor(NSColor.labelColor.cgColor)
            context.fillPath()
        case .symbol(let name):
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.labelColor]))
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return }
            // Keep the symbol's own aspect ratio, centered in the icon box.
            let size = symbol.size
            let scale = min(rect.width / size.width, rect.height / size.height, 1)
            let fitted = NSSize(width: size.width * scale, height: size.height * scale)
            let origin = NSPoint(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2)
            symbol.draw(in: NSRect(origin: origin, size: fitted), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    private static func draw(pct: Double?, x: CGFloat, y: CGFloat) {
        let radius = barHeight / 2
        NSColor.secondaryLabelColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: x, y: y, width: barsWidth, height: barHeight),
            xRadius: radius, yRadius: radius
        ).fill()

        guard let pct, pct > 0 else { return }
        let filled = max(barHeight, barsWidth * min(pct, 100) / 100)
        Theme.nsColor(for: UsageLevel(pct: pct)).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: x, y: y, width: filled, height: barHeight),
            xRadius: radius, yRadius: radius
        ).fill()
    }
}
