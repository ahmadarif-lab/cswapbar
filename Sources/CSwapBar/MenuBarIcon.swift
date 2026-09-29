import AppKit

/// Draws the menu bar's mini usage bars (5h on top, 7d below).
///
/// Rendered as an NSImage rather than SwiftUI shapes: MenuBarExtra reliably
/// renders only Text/Image in its label -- Capsule/Canvas draw nothing there.
enum MenuBarIcon {
    /// `topPct`/`bottomPct` are usually a provider's 5-hour/weekly windows,
    /// already condensed to one number per window (see
    /// `[ProviderAccount].menuBarPercentages()`).
    static func make(topPct: Double?, bottomPct: Double?) -> NSImage {
        let width: CGFloat = 22
        let barHeight: CGFloat = 3
        let gap: CGFloat = 3
        let size = NSSize(width: width, height: barHeight * 2 + gap)

        let image = NSImage(size: size, flipped: false) { _ in
            draw(pct: bottomPct, y: 0, width: width, height: barHeight)
            draw(pct: topPct, y: barHeight + gap, width: width, height: barHeight)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// A provider's logo as a template image, tinted by the menu bar itself.
    static func glyph(_ glyph: ProviderGlyph) -> NSImage {
        let side: CGFloat = 15
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(glyph.path(in: rect).cgPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func draw(pct: Double?, y: CGFloat, width: CGFloat, height: CGFloat) {
        let radius = height / 2
        NSColor.secondaryLabelColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 0, y: y, width: width, height: height),
            xRadius: radius, yRadius: radius
        ).fill()

        guard let pct, pct > 0 else { return }
        let filled = max(height, width * min(pct, 100) / 100)
        Theme.nsColor(for: UsageLevel(pct: pct)).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 0, y: y, width: filled, height: height),
            xRadius: radius, yRadius: radius
        ).fill()
    }
}
