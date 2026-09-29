import Foundation

/// Faithful port of CodexBar's own `zai.js` provider plugin (read in full
/// from the already-installed CodexBar.app, not a published schema) --
/// isolated from networking so it's unit-testable against captured JSON.
enum ZAIQuotaParsing {
    private static let tokenLimitTypes: Set<String> = ["TOKENS_LIMIT", "CREDIT_LIMIT"]
    /// unit -> minutes-per-unit: 1=day, 3=hour, 5=minute, 6=week.
    private static let windowMultipliers: [Int: Int] = [1: 1440, 3: 60, 5: 1, 6: 10080]
    private static let unitNames: [Int: String] = [1: "day", 3: "hour", 5: "minute", 6: "week"]

    struct ParsedLimit {
        let type: String
        let unit: Int
        let number: Int
        let percent: Double
        let usage: Int?
        let currentValue: Int?
        let remaining: Int?
        let windowMinutes: Int?
        let resetMillis: Int64?
        let details: [ZAIUsageDetail]
    }

    struct WindowInfo {
        let pctUsed: Double
        let resetsAt: Date?
        let label: String
    }

    static func summarize(_ response: ZAIQuotaResponse) throws -> ZAIAccountSummary {
        guard response.success == true, let rawLimits = response.data?.limits else {
            throw ZAIEngineError.decoding("unexpected response shape")
        }

        let limits = rawLimits.compactMap(parseLimit)
        let tokenLimits = limits
            .filter { tokenLimitTypes.contains($0.type) }
            .sorted { ($0.windowMinutes ?? .max) < ($1.windowMinutes ?? .max) }
        let timeLimit = limits.last { $0.type == "TIME_LIMIT" }
        // The largest-window token limit (e.g. a weekly/session cap sitting
        // alongside the 5-hour one), distinct from the smallest-window
        // "primary" below.
        let tokenLimit = tokenLimits.last
        let primaryLimit = tokenLimits.first ?? timeLimit

        var pools: [ZAIUsagePool] = []
        if let primaryLimit {
            let w = windowInfo(primaryLimit)
            pools.append(ZAIUsagePool(kind: .primary, label: w.label, pctUsed: w.pctUsed, resetsAt: w.resetsAt))
        }
        if tokenLimits.count >= 2, let tokenLimit {
            let w = windowInfo(tokenLimit)
            pools.append(ZAIUsagePool(kind: .secondary, label: w.label, pctUsed: w.pctUsed, resetsAt: w.resetsAt))
        }
        // The MCP bar only appears when the account also has a token limit
        // (matching zai.js: `if (tokenLimit && timeLimit)`), so an
        // MCP-only-looking account (edge case) doesn't show a lone,
        // out-of-context "MCP" bar with nothing to compare it to.
        if tokenLimit != nil, let timeLimit {
            let w = windowInfo(timeLimit)
            pools.append(ZAIUsagePool(kind: .mcp, label: "MCP", pctUsed: w.pctUsed, resetsAt: w.resetsAt))
        }

        var detailRows: [ZAIDetailRow] = []
        if let tokenLimit {
            detailRows.append(limitRow(tokenLimit.type == "CREDIT_LIMIT" ? "Credit quota" : "Token quota", tokenLimit))
        }
        if tokenLimits.count >= 2, let primaryLimit {
            detailRows.append(limitRow(primaryLimit.type == "CREDIT_LIMIT" ? "Session credit quota" : "Session token quota", primaryLimit))
        }
        if let timeLimit {
            detailRows.append(limitRow("MCP quota", timeLimit))
            for detail in timeLimit.details.prefix(20) {
                if let modelCode = detail.modelCode, let usage = detail.usage {
                    detailRows.append(ZAIDetailRow(label: modelCode, value: String(usage), secondaryValue: nil))
                }
            }
        }

        let planName = [response.data?.planName, response.data?.plan, response.data?.planType, response.data?.packageName, response.data?.level]
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        return ZAIAccountSummary(planName: planName, pools: pools, detailRows: detailRows)
    }

    /// Unrecognized `type` values are dropped (`nil`) rather than guessed at.
    private static func parseLimit(_ raw: ZAILimit) -> ParsedLimit? {
        guard let type = raw.type, ["TOKENS_LIMIT", "TIME_LIMIT", "CREDIT_LIMIT"].contains(type) else { return nil }
        guard let unit = raw.unit, let number = raw.number, let percentage = raw.percentage else { return nil }

        var percent = Double(percentage)
        if let usage = raw.usage, usage > 0 {
            var used: Int?
            if let remaining = raw.remaining {
                used = max(usage - remaining, raw.currentValue ?? (usage - remaining))
            } else if let current = raw.currentValue {
                used = current
            }
            if let used {
                percent = pct(Double(max(0, min(usage, used))), Double(usage))
            }
        }
        percent = max(0, min(100, percent))

        let windowMinutes: Int? = number > 0 ? windowMultipliers[unit].map { $0 * number } : nil

        return ParsedLimit(
            type: type, unit: unit, number: number, percent: percent,
            usage: raw.usage, currentValue: raw.currentValue, remaining: raw.remaining,
            windowMinutes: windowMinutes, resetMillis: raw.nextResetTime, details: raw.usageDetails ?? []
        )
    }

    private static func pct(_ numerator: Double, _ denominator: Double) -> Double {
        denominator > 0 ? (numerator / denominator) * 100 : 0
    }

    /// Ports `window(limit)` from zai.js: resolves the display label and
    /// decides whether the server's reset timestamp is even plausible.
    private static func windowInfo(_ limit: ParsedLimit, now: Date = Date()) -> WindowInfo {
        // A five-hour Coding Plan reset can't plausibly be ten hours away;
        // never trust (or display) a reset time that contradicts its own window.
        let isFiveHourPlan = limit.type != "TIME_LIMIT" && limit.windowMinutes == 300
        var resetsAt: Date?
        if let resetMillis = limit.resetMillis {
            let candidate = Date(timeIntervalSince1970: Double(resetMillis) / 1000)
            let plausible = !isFiveHourPlan || candidate <= now.addingTimeInterval(5 * 3600 + 60)
            if plausible { resetsAt = candidate }
        }

        let label: String
        if limit.type == "TIME_LIMIT" {
            label = "MCP"
        } else if limit.windowMinutes == 300 {
            label = "5-hour"
        } else if limit.windowMinutes != nil, let name = unitNames[limit.unit] {
            label = "\(limit.number) \(name)\(limit.number == 1 ? "" : "s") window"
        } else {
            label = "Usage"
        }

        return WindowInfo(pctUsed: limit.percent, resetsAt: resetsAt, label: label)
    }

    private static func limitRow(_ label: String, _ limit: ParsedLimit) -> ZAIDetailRow {
        var parts: [String] = []
        if let usage = limit.usage { parts.append("\(usage) limit") }
        if let remaining = limit.remaining { parts.append("\(remaining) remaining") }
        // Round to a tenth first: the usage/remaining ratio computed above
        // can land a hair off a whole number in floating point (e.g.
        // 6.999999999998), which would otherwise show a spurious ".0".
        let rounded = (limit.percent * 10).rounded() / 10
        let hasFraction = rounded.truncatingRemainder(dividingBy: 1) != 0
        let pctText = String(format: hasFraction ? "%.1f" : "%.0f", rounded)
        return ZAIDetailRow(label: label, value: "\(pctText)% used", secondaryValue: parts.isEmpty ? nil : parts.joined(separator: " · "))
    }
}
