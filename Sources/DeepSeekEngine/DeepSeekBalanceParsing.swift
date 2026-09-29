import Foundation

/// Isolated from networking so it's unit-testable against captured JSON.
enum DeepSeekBalanceParsing {
    static func summarize(_ response: DeepSeekBalanceResponse) throws -> DeepSeekBalanceSummary {
        let infos = response.balanceInfos ?? []
        // Matches CodexBar: with several currencies on one account, USD wins.
        guard let info = infos.first(where: { $0.currency?.uppercased() == "USD" }) ?? infos.first else {
            throw DeepSeekEngineError.decoding("no balance entries")
        }
        return DeepSeekBalanceSummary(
            isAvailable: response.isAvailable ?? false,
            currency: info.currency?.uppercased() ?? "USD",
            total: amount(info.totalBalance),
            granted: amount(info.grantedBalance),
            toppedUp: amount(info.toppedUpBalance)
        )
    }

    private static func amount(_ raw: String?) -> Double {
        raw.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } ?? 0
    }
}
