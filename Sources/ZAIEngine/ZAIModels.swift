import Foundation

public enum ZAIRegion: String, CaseIterable, Sendable {
    case global
    case china

    public var baseURL: URL {
        switch self {
        case .global: return URL(string: "https://api.z.ai")!
        case .china: return URL(string: "https://open.bigmodel.cn")!
        }
    }

    public var title: String {
        switch self {
        case .global: return "Global (api.z.ai)"
        case .china: return "China (open.bigmodel.cn)"
        }
    }
}

/// Which bar a pool renders as: the account's main token window (usually
/// 5-hour), a second token window some plans also carry (e.g. weekly), or
/// the separate MCP (tool-call) allowance -- ported from CodexBar's own
/// `zai.js`, which computes exactly this three-way split.
public enum ZAIPoolKind: Sendable, Equatable {
    case primary
    case secondary
    case mcp
}

public struct ZAIUsagePool: Sendable, Equatable {
    public let kind: ZAIPoolKind
    /// CodexBar's own dynamic reset description ("5-hour", "MCP", "3 days
    /// window", ...) -- not a fixed Session/Weekly label, since the window
    /// size genuinely varies by plan and limit type.
    public let label: String
    public let pctUsed: Double?
    public let resetsAt: Date?
}

public struct ZAIDetailRow: Sendable, Equatable {
    public let label: String
    public let value: String
    public let secondaryValue: String?
}

public struct ZAIAccountSummary: Sendable, Equatable {
    public let planName: String?
    public let pools: [ZAIUsagePool]
    public let detailRows: [ZAIDetailRow]
}

/// `GET /api/monitor/usage/quota/limit` -- reverse engineered by reading
/// CodexBar's own bundled `zai.js` provider plugin in full (not a published
/// schema), so every field stays optional and unrecognized keys are ignored
/// rather than failing the decode.
struct ZAIQuotaResponse: Decodable {
    let success: Bool?
    let code: Int?
    let data: ZAIQuotaData?
}

struct ZAIQuotaData: Decodable {
    let limits: [ZAILimit]?
    let planName: String?
    let plan: String?
    let packageName: String?
    let level: String?
    // `plan_type` is the one snake_case field among otherwise camelCase
    // plan-name candidates in the real response.
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case limits, planName, plan, packageName, level
        case planType = "plan_type"
    }
}

struct ZAIUsageDetail: Decodable {
    let modelCode: String?
    let usage: Int?
}

struct ZAILimit: Decodable {
    /// "TOKENS_LIMIT" | "TIME_LIMIT" (the MCP allowance) | "CREDIT_LIMIT".
    let type: String?
    /// Window size: unit 1=day, 3=hour, 5=minute, 6=week; combined with
    /// `number` (e.g. unit 3 + number 5 = the 5-hour window). For a
    /// TIME_LIMIT specifically, unit 5 + number 1 is a special marker for a
    /// 30-day (monthly) window rather than a literal 1-minute one.
    let unit: Int?
    let number: Int?
    /// Fallback percent-used, only consulted when usage/remaining/current
    /// aren't present to compute the same number directly.
    let percentage: Int?
    let usage: Int?
    let currentValue: Int?
    let remaining: Int?
    let nextResetTime: Int64?
    /// Per-tool call counts on the MCP (TIME_LIMIT) entry, e.g. "search-prime": 7.
    let usageDetails: [ZAIUsageDetail]?
}
