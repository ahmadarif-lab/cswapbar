import Foundation

extension Array where Element == ProviderAccount {
    /// The worst (highest) percent used across the *relevant* accounts'
    /// pools sharing a window, condensing any number of named pools (e.g.
    /// Antigravity's Gemini + Claude/GPT) into the same two-bar menu bar
    /// icon every provider uses.
    ///
    /// For a multi-account provider (Claude), only the active account is
    /// relevant -- an inactive managed account's usage has no bearing on
    /// what's happening right now, so it must not be able to outrank the
    /// active one's own numbers on the icon. Every other provider's
    /// accounts (Antigravity, z.ai: one synthetic account, possibly several
    /// pools) have no such concept and all of them count.
    func menuBarPercentages() -> (top: Double?, bottom: Double?) {
        let isMultiAccount = contains { $0.claudeDetail != nil }
        let relevant = isMultiAccount ? filter { $0.claudeDetail?.active == true } : self
        func worst(_ window: PoolWindow) -> Double? {
            relevant.flatMap(\.pools).filter { $0.window == window }.compactMap(\.pctUsed).max()
        }
        return (worst(.fiveHour), worst(.weekly))
    }
}
