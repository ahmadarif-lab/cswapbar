import Foundation

public struct AntigravityUsagePool: Sendable, Equatable {
    /// "Gemini" or "Claude/GPT" -- Antigravity splits quota across these two
    /// pools per the `-gemini-` / `-3p-` bucket ids in the quota response.
    public let poolName: String
    public let windowLabel: String
    public let pctUsed: Double?
    public let resetsAt: Date?
}

public struct AntigravityAccountSummary: Sendable, Equatable {
    public let pools: [AntigravityUsagePool]
}

public enum AntigravityEngineError: LocalizedError, Equatable {
    case notConfigured
    case http(Int, String)
    case network(String)
    case decoding(String)
    case autoDetect(String)
    case warmup(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "No Antigravity account connected."
        case .http(let code, let body): return "Antigravity returned HTTP \(code): \(body)"
        case .network(let message): return "Antigravity request failed: \(message)"
        case .decoding(let message): return "Could not read Antigravity's response: \(message)"
        case .autoDetect(let message): return message
        case .warmup(let message): return message
        }
    }
}
