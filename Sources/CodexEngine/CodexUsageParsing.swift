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

/// `GET https://chatgpt.com/backend-api/accounts/check/v4-2023-04-27`: one
/// entry per account under `accounts`, each with an `entitlement` block. Like
/// the usage endpoint it isn't published, so everything is optional.
struct CodexAccountCheckResponse: Decodable {
    let accounts: [String: Account]?

    struct Account: Decodable {
        let entitlement: Entitlement?
        let lastActiveSubscription: LastActiveSubscription?

        enum CodingKeys: String, CodingKey {
            case entitlement
            case lastActiveSubscription = "last_active_subscription"
        }
    }

    /// Where a cancellation shows up: the entitlement keeps its `renews_at`
    /// (and a null `cancels_at`) after "Cancel plan", only this flips.
    struct LastActiveSubscription: Decodable {
        let willRenew: Bool?

        enum CodingKeys: String, CodingKey {
            case willRenew = "will_renew"
        }
    }

    struct Entitlement: Decodable {
        let hasActiveSubscription: Bool?
        let renewsAt: String?
        let cancelsAt: String?
        let expiresAt: String?

        enum CodingKeys: String, CodingKey {
            case hasActiveSubscription = "has_active_subscription"
            case renewsAt = "renews_at"
            case cancelsAt = "cancels_at"
            case expiresAt = "expires_at"
        }
    }
}

extension CodexUsageParsing {
    /// The entitlement of the account the login belongs to (the response also
    /// carries a `default` entry), as a subscription. Nil without an active
    /// paid plan or a usable date.
    static func subscription(from response: CodexAccountCheckResponse, accountID: String) -> CodexSubscription? {
        guard let accounts = response.accounts,
              let account = accounts[accountID] ?? accounts["default"] ?? accounts.values.first,
              let entitlement = account.entitlement,
              entitlement.hasActiveSubscription == true else { return nil }
        let cancelsAt = entitlement.cancelsAt.flatMap(date(fromISO:))
        let cancelled = cancelsAt != nil || account.lastActiveSubscription?.willRenew == false
        // `expires_at` runs a few hours past the billing date as a grace
        // period, so it is only the fallback.
        let candidates = cancelled
            ? [cancelsAt, entitlement.renewsAt.flatMap(date(fromISO:)), entitlement.expiresAt.flatMap(date(fromISO:))]
            : [entitlement.renewsAt.flatMap(date(fromISO:)), entitlement.expiresAt.flatMap(date(fromISO:))]
        guard let date = candidates.compactMap({ $0 }).first else { return nil }
        return CodexSubscription(date: date, isCancelled: cancelled)
    }

    /// ChatGPT sends `2026-11-10T12:10:09+00:00`, sometimes with fractional
    /// seconds.
    static func date(fromISO raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
