import Foundation

/// Maps a quota-summary JSON body into the pools CSwapBar shows. Handles two
/// shapes:
///
/// - The local hub's (confirmed against a real running `agy --hub`): each
///   bucket is one window directly -- `{"bucketId": "gemini-weekly",
///   "window": "weekly", "remainingFraction": 0.68, "resetTime": "..."}`.
/// - The cloud API's (reverse engineered from CodexBar's binary, never
///   confirmed against a real response -- every account tried against it so
///   far comes back 403 SUBSCRIPTION_REQUIRED before reaching this shape):
///   each bucket carries both windows as separate field pairs --
///   `five_hour_usage_left_rate` / `five_hour_usage_reset_time` and
///   `weekly_usage_left_rate` / `weekly_usage_reset_time`.
///
/// Isolated from networking so it's unit-testable against captured
/// payloads, and tree-walks for anything that looks like a bucket rather
/// than assuming one fixed envelope nesting.
enum AntigravityQuotaParsing {
    /// Every JSON object in the tree that looks like a quota bucket (has a
    /// `bucketId`/`bucket_id` field), found via full recursive walk.
    static func findBuckets(_ json: Any) -> [[String: Any]] {
        var found: [[String: Any]] = []
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if dict["bucketId"] != nil || dict["bucket_id"] != nil {
                    found.append(dict)
                }
                for value in dict.values { walk(value) }
            } else if let array = node as? [Any] {
                for item in array { walk(item) }
            }
        }
        walk(json)
        return found
    }

    static func summarize(_ json: Any) -> AntigravityAccountSummary {
        var pools: [AntigravityUsagePool] = []
        // The hub's real response lists each pool's weekly bucket before its
        // 5h one, but the UI wants the shorter/more-urgent window on top --
        // sort after collecting rather than relying on source order.
        var poolOrder: [String: Int] = [:]
        for bucket in findBuckets(json) {
            let bucketID = ((bucket["bucketId"] as? String) ?? (bucket["bucket_id"] as? String) ?? "").lowercased()
            let poolName: String
            if bucketID.contains("gemini") {
                poolName = "Gemini"
            } else if bucketID.contains("3p") {
                poolName = "Claude/GPT"
            } else {
                continue // an unrecognized pool kind -- skip rather than guess
            }
            if poolOrder[poolName] == nil { poolOrder[poolName] = poolOrder.count }

            if let windowRaw = bucket["window"] as? String {
                // Hub shape: one bucket, one window, directly.
                if let remaining = fraction(bucket["remainingFraction"]) {
                    pools.append(AntigravityUsagePool(
                        poolName: poolName, windowLabel: windowLabel(windowRaw),
                        pctUsed: pctUsed(fromRemainingFraction: remaining), resetsAt: resetDate(bucket["resetTime"])
                    ))
                }
                continue
            }

            // Cloud-API shape: one bucket, both windows via separate fields.
            if let remaining = fraction(bucket["five_hour_usage_left_rate"]) {
                pools.append(AntigravityUsagePool(
                    poolName: poolName, windowLabel: "Session (5h)",
                    pctUsed: pctUsed(fromRemainingFraction: remaining), resetsAt: resetDate(bucket["five_hour_usage_reset_time"])
                ))
            }
            if let remaining = fraction(bucket["weekly_usage_left_rate"]) {
                pools.append(AntigravityUsagePool(
                    poolName: poolName, windowLabel: "Weekly",
                    pctUsed: pctUsed(fromRemainingFraction: remaining), resetsAt: resetDate(bucket["weekly_usage_reset_time"])
                ))
            }
        }
        let sorted = pools.sorted { a, b in
            let orderA = poolOrder[a.poolName] ?? 0
            let orderB = poolOrder[b.poolName] ?? 0
            if orderA != orderB { return orderA < orderB }
            return windowRank(a.windowLabel) < windowRank(b.windowLabel)
        }
        return AntigravityAccountSummary(pools: sorted)
    }

    private static func windowLabel(_ raw: String) -> String {
        switch raw {
        case "5h": return "Session (5h)"
        case "weekly": return "Weekly"
        default: return raw.capitalized
        }
    }

    /// 5h above weekly within a pool -- the shorter, more time-pressured
    /// window belongs on top.
    private static func windowRank(_ label: String) -> Int {
        switch label {
        case "Session (5h)": return 0
        case "Weekly": return 1
        default: return 2
        }
    }

    private static func pctUsed(fromRemainingFraction remaining: Double) -> Double {
        max(0, min(100, 100 - remaining * 100))
    }

    private static func fraction(_ value: Any?) -> Double? {
        switch value {
        case let n as Double: return n
        case let n as Int: return Double(n)
        case let s as String: return Double(s)
        default: return nil
        }
    }

    private static func resetDate(_ value: Any?) -> Date? {
        guard let raw = value as? String else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: raw)
    }
}
