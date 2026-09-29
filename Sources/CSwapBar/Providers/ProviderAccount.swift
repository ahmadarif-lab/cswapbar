import Foundation

struct ProviderAccount: Identifiable, Equatable {
    let id: String
    let displayName: String
    let subtitle: String?
    let pools: [UsagePool]
    /// A short human status ("ok", "rate-limited", "no usage data"...) shown
    /// when there's no usable pool data.
    let statusText: String?
    /// True when `pools` reflect a last-known measurement rather than a
    /// fresh fetch (Claude's `lastGoodUsage` fallback).
    let isStale: Bool
    /// How old that last-known measurement is, when `isStale`.
    let staleAgeSeconds: Double?
    /// Claude-only concepts (active slot, disabled) that generic views don't
    /// need to know about; kept behind a small struct instead of widening
    /// every provider's account shape.
    let claudeDetail: ClaudeAccountDetail?
    /// Extra label/value rows below the usage bars (z.ai's token/MCP quota
    /// breakdown and per-tool call counts) -- empty for providers that don't
    /// have anything beyond the bars themselves.
    let detailRows: [ProviderDetailRow]
    /// Prepaid credit instead of usage windows (DeepSeek) -- shown in place
    /// of the bars, and as text next to the menu bar icon.
    let balance: ProviderBalance?

    init(
        id: String, displayName: String, subtitle: String? = nil, pools: [UsagePool] = [],
        statusText: String? = nil, isStale: Bool = false, staleAgeSeconds: Double? = nil,
        claudeDetail: ClaudeAccountDetail? = nil, detailRows: [ProviderDetailRow] = [],
        balance: ProviderBalance? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.subtitle = subtitle
        self.pools = pools
        self.statusText = statusText
        self.isStale = isStale
        self.staleAgeSeconds = staleAgeSeconds
        self.claudeDetail = claudeDetail
        self.detailRows = detailRows
        self.balance = balance
    }
}

struct ProviderBalance: Equatable {
    /// Already formatted with its currency, e.g. "$50.00".
    let total: String
    /// e.g. "Paid: $40.00 / Granted: $10.00".
    let breakdown: String?
    /// Set when the balance can't pay for API calls (empty, or DeepSeek
    /// reports it unavailable) -- drawn in the warning color.
    let warning: String?
}

struct ClaudeAccountDetail: Equatable {
    let number: Int
    let active: Bool
    let isDisabled: Bool
}

struct ProviderDetailRow: Identifiable, Equatable {
    var id: String { label }
    let label: String
    let value: String
    let secondaryValue: String?

    init(label: String, value: String, secondaryValue: String? = nil) {
        self.label = label
        self.value = value
        self.secondaryValue = secondaryValue
    }
}
