import Foundation

/// `pace.py`: whether a weekly window is being used faster than the week
/// is passing. JSON-only fields; never touches poll cadence.
enum Pace {
    static let weeklyPeriod: Double = 7 * 86400
    static let suppressAfterReset: Double = 24 * 3600
    static let aheadThresholdPct: Double = 15

    struct Result {
        let expectedPct: Double
        let actualPct: Double
        let elapsed: Double
        let period: Double
        let ahead: Bool
    }

    static func compute(_ window: JSONObject?, fetchedAt: Double?) -> Result? {
        guard let window, let fetchedAt, let pct = window["pct"]?.numberValue?.doubleValue,
              let resetsAt = window["resets_at"]?.stringValue,
              let nextReset = TimeFormat.parseISO(resetsAt)?.timeIntervalSince1970 else { return nil }
        let remaining = pyMod(nextReset - fetchedAt, weeklyPeriod)
        let elapsed = remaining == 0 ? 0 : weeklyPeriod - remaining
        if elapsed < suppressAfterReset { return nil }
        let expected = min(100.0, (elapsed / weeklyPeriod) * 100.0)
        return Result(
            expectedPct: expected,
            actualPct: pct,
            elapsed: elapsed,
            period: weeklyPeriod,
            ahead: (pct - expected) >= aheadThresholdPct
        )
    }

    static func projectedExhaustion(_ pace: Result, fetchedAt: Double) -> Double? {
        guard pace.elapsed > 0, pace.actualPct > 0 else { return nil }
        let rate = pace.actualPct / pace.elapsed
        guard rate > 0 else { return nil }
        let remaining = 100.0 - pace.actualPct
        if remaining <= 0 { return fetchedAt }
        return fetchedAt + remaining / rate
    }

    static func willLastToReset(_ pace: Result) -> Bool? {
        if pace.actualPct <= 0 { return true }
        guard pace.elapsed > 0 else { return nil }
        let rate = pace.actualPct / pace.elapsed
        guard rate > 0 else { return nil }
        return pace.actualPct + rate * (pace.period - pace.elapsed) <= 100.0
    }

    /// Python's `%` on floats: the result takes the divisor's sign.
    static func pyMod(_ a: Double, _ b: Double) -> Double {
        let r = fmod(a, b)
        return (r != 0 && (r < 0) != (b < 0)) ? r + b : r
    }
}

/// `poll_policy.py`: the usage endpoint's request budget, in one place.
enum PollPolicy {
    static let serveTTL: Double = 180
    static let minInterval: Double = 180
    static let urgentInterval: Double = 60
    static let activeMaxInterval: Double = 300
    static let candidateDefaultInterval: Double = 300
    static let candidateMaxInterval: Double = 600
    static let exhaustedInterval: Double = 600
    static let movementDeltaPct: Double = 1
    static let jitterFrac: Double = 0.1
    static let edgeBackoff: Double = 300
    static let post429MinInterval: Double = 360
    static let recent429Window: Double = 3600
    static let post429BackoffMult: Double = 1.5
    static let post429MaxInterval: Double = 1800
    static let escalationMarginPct: Double = 15
    static let resetSlack: Double = 60

    static func bindingPct(_ usage: JSONValue?, models: [String]) -> Double? {
        OAuth.accountHeadroom(usage, models: models).map { 100.0 - $0 }
    }

    static func parseResetTs(_ resetsAt: String?) -> Double? {
        guard let resetsAt, !resetsAt.isEmpty else { return nil }
        return TimeFormat.parseISO(resetsAt.replacingOccurrences(of: "Z", with: "+00:00"))?.timeIntervalSince1970
    }

    static func limitingResetTs(_ usage: JSONValue?, models: [String]) -> Double? {
        var latest: Double?
        for w in OAuth.relevantWindows(usage, models: models) where w.pct >= 100 {
            if let ts = parseResetTs(w.resetsAt), latest == nil || ts > latest! { latest = ts }
        }
        return latest
    }

    static func earliestFutureResetTs(_ usage: JSONValue?, now: Double, models: [String]) -> Double? {
        var earliest: Double?
        for w in OAuth.relevantWindows(usage, models: models) {
            if let ts = parseResetTs(w.resetsAt), ts > now, earliest == nil || ts < earliest! { earliest = ts }
        }
        return earliest
    }

    /// `plan_after_fetch`: `(nextPollAt, interval)` after a successful fetch.
    static func planAfterFetch(
        prevInterval: Double?,
        prevUsage: JSONValue?,
        newUsage: JSONValue?,
        isActive: Bool,
        threshold: Double,
        models: [String],
        recent429: Bool,
        now: Double,
        rng: () -> Double = { Double.random(in: 0..<1) }
    ) -> (nextPollAt: Double, interval: Double) {
        let defaultInterval = isActive ? minInterval : candidateDefaultInterval
        let ceiling = isActive ? activeMaxInterval : candidateMaxInterval
        let base = (prevInterval.flatMap { $0 == 0 ? nil : $0 }) ?? defaultInterval
        let prevPct = bindingPct(prevUsage, models: models)
        let newPct = bindingPct(newUsage, models: models)
        var moving = false
        var interval: Double
        if let prevPct, let newPct {
            if abs(newPct - prevPct) >= movementDeltaPct {
                moving = true
                interval = max(minInterval, base / 2)
            } else {
                interval = min(ceiling, max(minInterval, base * 1.5))
            }
        } else {
            interval = defaultInterval
        }
        if isActive, moving, !recent429, let newPct, newPct >= threshold - escalationMarginPct {
            interval = urgentInterval
        }
        if recent429 {
            let increased = max(base * post429BackoffMult, post429MinInterval)
            interval = min(post429MaxInterval, max(interval, increased))
        }

        let headroom = OAuth.accountHeadroom(newUsage, models: models)
        if let headroom, headroom <= 0 {
            interval = max(interval, exhaustedInterval)
        }

        var nextPoll = now + interval * (1.0 + jitterFrac * (2.0 * rng() - 1.0))
        if let headroom, headroom <= 0 {
            if let reset = limitingResetTs(newUsage, models: models), reset > now {
                nextPoll = min(nextPoll, reset + resetSlack)
            }
        } else if let reset = earliestFutureResetTs(newUsage, now: now, models: models) {
            nextPoll = min(nextPoll, reset + resetSlack)
        }
        return (nextPoll, interval)
    }
}
