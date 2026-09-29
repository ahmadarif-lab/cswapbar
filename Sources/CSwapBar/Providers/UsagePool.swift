import Foundation

enum PoolWindow: Equatable {
    case fiveHour
    case weekly
    /// A window that doesn't fit the two standard ones (z.ai's MCP
    /// allowance, or a plan-specific window size) -- always paired with
    /// `UsagePool.labelOverride`, and deliberately excluded from the menu
    /// bar icon's two-bar condensation (`[ProviderAccount].menuBarPercentages()`
    /// only looks at `.fiveHour`/`.weekly`), since a third+ metric belongs in
    /// the dropdown detail, not the compact icon.
    case other

    var defaultLabel: String {
        switch self {
        case .fiveHour: return "Session (5h)"
        case .weekly: return "Weekly (7d)"
        case .other: return "Usage"
        }
    }

    var shortLabel: String {
        switch self {
        case .fiveHour: return "5h"
        case .weekly: return "weekly"
        case .other: return "usage"
        }
    }
}

/// A single rate-limit window CSwapBar shows a bar for. `poolName` is nil
/// for a provider with one undifferentiated pool (Claude, z.ai) and set for
/// a provider that splits quota across named pools (Antigravity's Gemini vs.
/// Claude/GPT), so the same view code covers both shapes.
struct UsagePool: Identifiable, Equatable {
    let id: String
    let poolName: String?
    let window: PoolWindow
    /// Percent of the window already used (0-100), nil when unknown.
    let pctUsed: Double?
    let resetsAt: Date?
    /// Overrides the window's fixed Session/Weekly wording when a
    /// provider's own label doesn't fit that mold (z.ai's dynamic "5-hour"/
    /// "MCP"/"3 days window" descriptions, which genuinely vary by plan).
    let labelOverride: String?

    init(
        id: String, poolName: String? = nil, window: PoolWindow, pctUsed: Double?, resetsAt: Date?,
        labelOverride: String? = nil
    ) {
        self.id = id
        self.poolName = poolName
        self.window = window
        self.pctUsed = pctUsed
        self.resetsAt = resetsAt
        self.labelOverride = labelOverride
    }

    var label: String {
        if let labelOverride { return labelOverride }
        guard let poolName else { return window.defaultLabel }
        return "\(poolName) · \(window.shortLabel)"
    }
}
