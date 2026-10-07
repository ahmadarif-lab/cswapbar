import Foundation

/// Kiro bills against a monthly pool of credits, so there is a single window
/// to show: how much of that pool is spent, on which plan, and when it
/// refills. There is no rolling 5-hour window and no prepaid balance, which
/// is why this provider has no warm-up.
public struct KiroUsageSummary: Sendable, Equatable {
    /// The CLI's own plan label ("KIRO PRO"), when it reports one.
    public let planName: String?
    /// Percent of the monthly pool already used (0-100).
    public let pctUsed: Double
    /// What the pool counts ("Credits", "Requests") and its amounts, when the
    /// report spells them out.
    public let unit: String?
    public let used: Double?
    public let limit: Double?
    /// The date the pool refills.
    public let resetsAt: Date?
}
