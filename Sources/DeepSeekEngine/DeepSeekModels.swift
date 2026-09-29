import Foundation

/// The account's remaining prepaid credit, in the one currency CSwapBar
/// shows (USD preferred when the account holds several).
public struct DeepSeekBalanceSummary: Sendable, Equatable {
    /// False when DeepSeek reports the balance can't currently pay for API
    /// calls, even if it's nonzero.
    public let isAvailable: Bool
    public let currency: String
    public let total: Double
    /// Promotional credit DeepSeek granted.
    public let granted: Double
    /// Credit the user paid for.
    public let toppedUp: Double

    public var currencySymbol: String { currency == "CNY" ? "¥" : "$" }

    public func format(_ amount: Double) -> String {
        String(format: "\(currencySymbol)%.2f", amount)
    }
}

/// `GET https://api.deepseek.com/user/balance` -- the public, documented
/// balance endpoint CodexBar's DeepSeek provider also reads. Amounts come
/// back as decimal strings.
struct DeepSeekBalanceResponse: Decodable {
    let isAvailable: Bool?
    let balanceInfos: [DeepSeekBalanceInfo]?

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }
}

struct DeepSeekBalanceInfo: Decodable {
    let currency: String?
    let totalBalance: String?
    let grantedBalance: String?
    let toppedUpBalance: String?

    enum CodingKeys: String, CodingKey {
        case currency
        case totalBalance = "total_balance"
        case grantedBalance = "granted_balance"
        case toppedUpBalance = "topped_up_balance"
    }
}
