import Foundation

/// `GET https://chatgpt.com/backend-api/wham/usage` -- the endpoint behind the
/// usage readout in Codex's own `/status`. It isn't a published API, so every
/// field is optional and a window with missing numbers is dropped rather than
/// failing the whole report.
struct CodexUsageResponse: Decodable {
    let planType: String?
    let rateLimit: RateLimit?
    let credits: Credits?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
    }

    struct RateLimit: Decodable {
        let limitReached: Bool?
        let primaryWindow: Window?
        let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case limitReached = "limit_reached"
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct Window: Decodable {
        let usedPercent: Double?
        let limitWindowSeconds: Double?
        let resetAfterSeconds: Double?
        /// Unix time, in seconds.
        let resetAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAfterSeconds = "reset_after_seconds"
            case resetAt = "reset_at"
        }
    }

    struct Credits: Decodable {
        let hasCredits: Bool?
        let unlimited: Bool?
        /// A decimal string ("12.50") on the wire; a plain number decodes too.
        let balance: String?

        enum CodingKeys: String, CodingKey {
            case hasCredits = "has_credits"
            case unlimited
            case balance
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hasCredits = try? container.decode(Bool.self, forKey: .hasCredits)
            unlimited = try? container.decode(Bool.self, forKey: .unlimited)
            if let text = try? container.decode(String.self, forKey: .balance) {
                balance = text
            } else if let number = try? container.decode(Double.self, forKey: .balance) {
                balance = String(number)
            } else {
                balance = nil
            }
        }
    }
}

enum CodexUsageParsing {
    private static let fiveHours = 5 * 3600
    private static let week = 7 * 24 * 3600

    static func summarize(
        _ response: CodexUsageResponse, fallbackPlan: String? = nil, now: Date = Date()
    ) throws -> CodexUsageSummary {
        let slots: [(window: CodexUsageResponse.Window, fallback: CodexWindow.Kind)] = [
            response.rateLimit?.primaryWindow.map { ($0, .fiveHour) },
            response.rateLimit?.secondaryWindow.map { ($0, .weekly) },
        ].compactMap { $0 }

        let windows = slots.compactMap { parse($0.window, fallback: $0.fallback, now: now) }
        guard !windows.isEmpty else {
            throw CodexEngineError.decoding("no usable usage windows in the response")
        }
        return CodexUsageSummary(
            windows: windows,
            planName: planName(response.planType ?? fallbackPlan),
            creditBalance: creditBalance(response.credits),
            isLimitReached: response.rateLimit?.limitReached == true
        )
    }

    /// The server names its windows primary and secondary, but what they are
    /// depends on the plan, so the length decides -- the slot only stands in
    /// when the length is missing.
    private static func parse(
        _ window: CodexUsageResponse.Window, fallback: CodexWindow.Kind, now: Date
    ) -> CodexWindow? {
        guard let used = window.usedPercent, used.isFinite else { return nil }
        let seconds = window.limitWindowSeconds.flatMap { $0.isFinite && $0 > 0 ? Int($0) : nil }
        return CodexWindow(
            kind: seconds.map(kind(forSeconds:)) ?? fallback,
            pctUsed: min(max(used, 0), 100),
            resetsAt: resetDate(window, now: now)
        )
    }

    /// Windows are sold as "5 hours" and "7 days" but measured to the second,
    /// so a little slack keeps a slightly-off length from reading as a third kind.
    private static func kind(forSeconds seconds: Int) -> CodexWindow.Kind {
        if abs(seconds - fiveHours) <= 600 { return .fiveHour }
        if abs(seconds - week) <= 3600 { return .weekly }
        return .other(seconds: seconds)
    }

    private static func resetDate(_ window: CodexUsageResponse.Window, now: Date) -> Date? {
        if let at = window.resetAt, at.isFinite, at > 0 { return Date(timeIntervalSince1970: at) }
        if let after = window.resetAfterSeconds, after.isFinite { return now.addingTimeInterval(after) }
        return nil
    }

    private static func creditBalance(_ credits: CodexUsageResponse.Credits?) -> String? {
        guard let credits else { return nil }
        if credits.unlimited == true { return "Unlimited" }
        guard credits.hasCredits == true, let raw = credits.balance,
              let value = Double(raw.trimmingCharacters(in: .whitespaces)) else { return nil }
        return value.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }

    /// "plus" -> "Plus", "prolite" -> "Pro Lite" is not worth guessing at:
    /// unknown plans are just capitalized.
    static func planName(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }
}
