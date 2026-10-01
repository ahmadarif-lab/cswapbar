import Foundation

/// One of OpenCode Go's three subscription windows. OpenCode Go is a
/// flat-rate subscription, so there is no prepaid balance to read -- only how
/// much of each window is already spent.
public struct OpenCodeGoWindow: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        /// OpenCode's "rolling" window -- the 5-hour one.
        case rolling
        case weekly
        case monthly

        public var label: String {
            switch self {
            case .rolling: return "5-hour"
            case .weekly: return "Weekly"
            case .monthly: return "Monthly"
            }
        }
    }

    public let kind: Kind
    /// Percent of the window already used (0-100).
    public let pctUsed: Double
    public let resetsAt: Date?
    /// The server has already cut this window off (`"rate-limited"`).
    public let isRateLimited: Bool
    /// Spend and cap for this window. The console reports both in dollars;
    /// the API-key endpoint reports percents only, so these stay nil there.
    public let usedUSD: Double?
    public let limitUSD: Double?
}

public struct OpenCodeGoUsageSummary: Sendable, Equatable {
    public let windows: [OpenCodeGoWindow]
    /// "Go" or "Go Plus", when the console reports it.
    public let planName: String?
    /// End of the current billing period.
    public let renewsAt: Date?
}

// MARK: - API-key endpoint

/// `GET https://opencode.ai/zen/go/v1/usage`:
/// `{ "usage": { "rolling": …, "weekly": …, "monthly": … } }`. Some
/// third-party readers have also seen the windows at the top level instead, so
/// both shapes decode -- this endpoint is undocumented and has already changed
/// shape once, so nothing here is treated as guaranteed.
struct OpenCodeGoUsageResponse: Decodable {
    let usage: OpenCodeGoWindows?
    let rolling: OpenCodeGoWindowPayload?
    let weekly: OpenCodeGoWindowPayload?
    let monthly: OpenCodeGoWindowPayload?

    var windows: OpenCodeGoWindows {
        usage ?? OpenCodeGoWindows(rolling: rolling, weekly: weekly, monthly: monthly)
    }
}

struct OpenCodeGoWindows: Decodable {
    let rolling: OpenCodeGoWindowPayload?
    let weekly: OpenCodeGoWindowPayload?
    let monthly: OpenCodeGoWindowPayload?

    func payload(for kind: OpenCodeGoWindow.Kind) -> OpenCodeGoWindowPayload? {
        switch kind {
        case .rolling: return rolling
        case .weekly: return weekly
        case .monthly: return monthly
        }
    }
}

struct OpenCodeGoWindowPayload: Decodable {
    /// `"ok"` | `"rate-limited"`.
    let status: String?
    /// Percent used, 0-100.
    let percent: Double?
    /// ISO-8601 timestamp computed server side.
    let resetsAt: String?
    /// Tolerated alternate for `resetsAt`, in case the endpoint ever reports
    /// the countdown instead of the wall-clock time.
    let resetsInSeconds: Double?
}

// MARK: - Console endpoint

/// `GET https://opencode.ai/console/api/go/status` -- the same payload the
/// OpenCode console's own Go page renders, and the one an OAuth session (the
/// credential `opencode auth login` stores) can read. Unlike the API-key
/// endpoint it reports real money: `usedMicroCents` out of `limitMicroCents`.
struct OpenCodeGoConsoleStatus: Decodable {
    let product: String?
    let renewalProduct: String?
    /// True when the workspace falls back to prepaid Zen credit once the
    /// plan's own limits are used up.
    let useBalance: Bool?
    let access: Access?

    struct Access: Decodable {
        let startsAt: String?
        /// End of the billing period -- also the monthly window's reset, which
        /// the month meter itself doesn't carry.
        let endsAt: String?
        let meters: Meters?
    }

    struct Meters: Decodable {
        let fiveHour: Meter?
        let week: Meter?
        let month: Meter?
    }

    struct Meter: Decodable {
        let startsAt: String?
        let resetsAt: String?
        let limitMicroCents: MicroCents?
        let usedMicroCents: MicroCents?
    }
}

/// The console sends these amounts as decimal strings ("1200000000"), so both
/// a string and a plain number decode.
struct MicroCents: Decodable, Equatable {
    let value: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            value = Double(text.trimmingCharacters(in: .whitespaces))
        } else if let number = try? container.decode(Double.self) {
            value = number
        } else {
            value = nil
        }
    }

    /// Micro-cents are 1e-6 of a cent, i.e. 1e-8 of a dollar.
    var usd: Double? { value.map { $0 / 100_000_000 } }
}

/// `GET https://opencode.ai/console/api/orgs` -- the workspaces an OAuth
/// session can see.
struct OpenCodeGoWorkspace: Decodable {
    let id: String
}
