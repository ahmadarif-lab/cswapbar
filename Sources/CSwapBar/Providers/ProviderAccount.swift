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

    init(
        id: String, displayName: String, subtitle: String? = nil, pools: [UsagePool] = [],
        statusText: String? = nil, isStale: Bool = false, staleAgeSeconds: Double? = nil,
        claudeDetail: ClaudeAccountDetail? = nil, detailRows: [ProviderDetailRow] = []
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
    }
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
