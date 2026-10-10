import Foundation

/// One of the rate-limit windows a ChatGPT plan has for Codex. Plans differ in
/// which they carry -- Plus and Pro have a 5-hour window and a weekly one, a
/// free plan may have only the weekly one -- so the windows are classified by
/// their length rather than by which slot the server put them in.
public struct CodexWindow: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case fiveHour
        case weekly
        /// A window of some other length, in seconds.
        case other(seconds: Int)

        public var label: String {
            switch self {
            case .fiveHour: return "5-hour"
            case .weekly: return "Weekly"
            case .other(let seconds):
                let hours = Double(seconds) / 3600
                if hours >= 24, hours.truncatingRemainder(dividingBy: 24) == 0 {
                    return "\(Int(hours / 24))-day"
                }
                return "\(Int(hours.rounded()))-hour"
            }
        }
    }

    public let kind: Kind
    /// Percent of the window already used (0-100).
    public let pctUsed: Double
    public let resetsAt: Date?
}

public struct CodexUsageSummary: Sendable, Equatable {
    public let windows: [CodexWindow]
    /// "Plus", "Pro", "Team"... from the ChatGPT plan the account is on.
    public let planName: String?
    /// Prepaid Codex credits, shown as the server formats them. Nil when the
    /// plan has none.
    public let creditBalance: String?
    /// The server has stopped serving requests until a window resets.
    public let isLimitReached: Bool
}
