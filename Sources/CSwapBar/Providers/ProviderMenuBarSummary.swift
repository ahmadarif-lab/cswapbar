import Foundation

extension Array where Element == ProviderAccount {
    /// The worst (highest) percent used across every account's pools sharing
    /// a window, condensing any number of named pools (e.g. Antigravity's
    /// Gemini + Claude/GPT) into the same two-bar menu bar icon every
    /// provider uses.
    func menuBarPercentages() -> (top: Double?, bottom: Double?) {
        func worst(_ window: PoolWindow) -> Double? {
            flatMap(\.pools).filter { $0.window == window }.compactMap(\.pctUsed).max()
        }
        return (worst(.fiveHour), worst(.weekly))
    }
}
