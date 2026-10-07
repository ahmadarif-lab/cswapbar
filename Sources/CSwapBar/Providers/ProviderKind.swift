import AppKit
import SwiftUI

enum ProviderKind: String, CaseIterable, Identifiable {
    case claude
    case antigravity
    case zai
    case deepseek
    case opencodeGo
    case kiro

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .antigravity: return "Antigravity"
        case .zai: return "z.ai"
        case .deepseek: return "DeepSeek"
        case .opencodeGo: return "OpenCode Go"
        case .kiro: return "Kiro"
        }
    }

    var iconSource: ProviderIconSource {
        switch self {
        case .claude: return .symbol("sparkles")
        // Real logo marks, not generic stand-ins -- see ProviderGlyph.swift.
        case .antigravity: return .glyph(.antigravity)
        case .zai: return .glyph(.zai)
        case .deepseek: return .glyph(.deepseek)
        case .opencodeGo: return .glyph(.opencodeGo)
        case .kiro: return .glyph(.kiro)
        }
    }

    var defaultEnabled: Bool { self == .claude }

    /// How often this provider's own poll loop re-fetches. z.ai and Claude
    /// are cheap and move fast; OpenCode Go's quota endpoint is an
    /// undocumented, uncached server-side aggregate, so it's polled least.
    /// Kiro has no endpoint at all -- each read launches the CLI -- and its
    /// credits only move on a monthly cycle, so it's polled least of all.
    var refreshInterval: TimeInterval {
        switch self {
        case .claude, .zai: return 30
        case .antigravity, .deepseek: return 60
        case .opencodeGo: return 120
        case .kiro: return 300
        }
    }

    /// UserDefaults key for this provider's menu bar visibility.
    var showDefaultsKey: String { "cswapbar.show.\(rawValue)" }

    var accent: Color {
        switch self {
        case .claude: return Theme.accent
        // Google's own blue (#1A73E8), which Antigravity's brand palette uses.
        case .antigravity: return Color(red: 0x1A / 255, green: 0x73 / 255, blue: 0xE8 / 255)
        // z.ai's own mark is literally black-on-white (no brand hue to
        // match) -- flipped to a light neutral here since CSwapBar's own
        // chrome is dark-on-dark, where a near-black accent would be all
        // but invisible (the same reason CodexBar's own bundled SVG for
        // this icon is itself `fill="white"`, not black).
        case .zai: return Color(white: 0.82)
        // DeepSeek's own brand blue (#4D6BFE).
        case .deepseek: return Color(red: 0x4D / 255, green: 0x6B / 255, blue: 0xFE / 255)
        // OpenCode's brand is monochrome too; this is the grey its own site
        // leans on (#8E8B8B), deliberately darker than z.ai's so the two
        // neutral marks stay apart in the Settings sidebar.
        case .opencodeGo: return Color(white: 0x8E / 255)
        // Kiro's own logo lilac (#C695FF), the color its ">_" prompt mark is
        // drawn in. Light enough that the Settings sidebar's selected pill
        // flips to a dark foreground for it (see `isLight`).
        case .kiro: return Color(red: 0xC6 / 255, green: 0x95 / 255, blue: 0xFF / 255)
        }
    }
}

extension Color {
    /// Rough perceived-brightness check so text/icons drawn on top of an
    /// arbitrary accent color (the Settings sidebar's selected-tab pill)
    /// can pick a readable foreground instead of assuming every accent is
    /// dark enough for white on top.
    var isLight: Bool {
        guard let rgb = NSColor(self).usingColorSpace(.deviceRGB) else { return false }
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.6
    }
}

/// Either an SF Symbol or a custom vector mark (`ProviderGlyph`).
enum ProviderIconSource {
    case symbol(String)
    case glyph(ProviderGlyph)
}

struct ProviderIconView: View {
    let source: ProviderIconSource
    var size: CGFloat = 16

    var body: some View {
        switch source {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size))
        case .glyph(let glyph):
            glyph
                .fill()
                .frame(width: size, height: size)
        }
    }
}
