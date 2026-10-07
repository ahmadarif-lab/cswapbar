import AppKit

/// Draws the whole menu bar strip: one segment per shown provider, each with
/// its logo, its mini usage bars (5h on top, 7d below -- a single bar when
/// the provider only has one window) and its percentage or balance --
/// whichever `MenuBarStyle` asks for.
///
/// Everything, text included, goes into a single NSImage so every provider
/// lives in one status item and macOS can't slot other apps' items between
/// them. Not a template image, since the bars carry their own usage colors;
/// the logo and text are drawn in `labelColor` instead, resolved against the
/// menu bar's appearance at draw time just like the bars' track color.
enum MenuBarIcon {
    struct Segment {
        var icon: ProviderIconSource?
        /// Usually a provider's 5-hour/weekly windows, already condensed to
        /// one number per window (see `[ProviderAccount].menuBarPercentages()`).
        var bars: (top: Double?, bottom: Double?)?
        var text: String?
    }

    private static let iconSide: CGFloat = 15
    private static let barsWidth: CGFloat = 22
    private static let barHeight: CGFloat = 3
    private static let barGap: CGFloat = 3
    private static let spacing: CGFloat = 4
    /// Room between two providers' segments.
    private static let segmentGap: CGFloat = 10
    private static let font = NSFont.menuBarFont(ofSize: 11)

    /// The strip image plus each segment's horizontal extent within it
    /// (image coordinates), so a click can be mapped back to its provider.
    static func make(_ segments: [Segment]) -> (image: NSImage, spans: [ClosedRange<CGFloat>]) {
        let barsHeight = barHeight * 2 + barGap
        let widths = segments.map(width(of:))
        var spans: [ClosedRange<CGFloat>] = []
        var x: CGFloat = 0
        for width in widths {
            spans.append(x...(x + width))
            x += width + segmentGap
        }
        let totalWidth = max(x - segmentGap, 1)
        let textHeight = ceil(font.ascender - font.descender)
        let height = max(iconSide, barsHeight, textHeight)

        let image = NSImage(size: NSSize(width: totalWidth, height: height), flipped: true) { _ in
            for (segment, span) in zip(segments, spans) {
                var x = span.lowerBound
                if let icon = segment.icon {
                    draw(icon, in: NSRect(x: x, y: (height - iconSide) / 2, width: iconSide, height: iconSide))
                    x += iconSide + spacing
                }
                if let bars = segment.bars {
                    // Only as many bars as there are windows: a provider
                    // whose second window doesn't exist (Kiro's single
                    // monthly credit pool, or any provider missing its
                    // weekly figure) draws one bar, not one bar over an
                    // empty track that would read as "0% used".
                    let hasBottom = bars.bottom != nil
                    let stackHeight = hasBottom ? barsHeight : barHeight
                    let top = (height - stackHeight) / 2
                    draw(pct: bars.top, x: x, y: top)
                    if hasBottom { draw(pct: bars.bottom, x: x, y: top + barHeight + barGap) }
                    x += barsWidth + spacing
                }
                if let text = segment.text {
                    NSAttributedString(string: text, attributes: textAttributes)
                        .draw(at: NSPoint(x: x, y: (height - textHeight) / 2))
                }
            }
            return true
        }
        image.isTemplate = false
        return (image, spans)
    }

    private static var textAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.labelColor]
    }

    private static func width(of segment: Segment) -> CGFloat {
        var parts: [CGFloat] = []
        if segment.icon != nil { parts.append(iconSide) }
        if segment.bars != nil { parts.append(barsWidth) }
        if let text = segment.text {
            parts.append(ceil(NSAttributedString(string: text, attributes: textAttributes).size().width))
        }
        return parts.reduce(0, +) + spacing * CGFloat(max(parts.count - 1, 0))
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
